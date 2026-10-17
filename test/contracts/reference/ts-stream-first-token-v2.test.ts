import { MonotonicClockGateway } from './monotonic-clock-gateway';
import { OpenAIGateway } from './gateways/openai';
import { OllamaGateway } from './gateways/ollama';
import { LlmGateway } from './gateway';
import { LlmBroker } from './broker';
import { ChatSession } from './chat-session';
import { CompletionEvidence, LlmStreamEvent } from './stream-events';
import { Ok, Result, unwrap } from '../error';
import { LlmTool } from './tools';
import { StreamChunk } from './models';
import { createServer } from 'node:http';
import { AddressInfo } from 'node:net';
import { OMLXGateway } from './gateways/omlx';
import { Message } from './models';
import { inspectRecoveryFailure, RecoveryError, RecoveryOptions } from './recovery';

it('measures the first argument before an oMLX terminal failure through real HTTP', async () => {
  let now = 10;
  const clock = jest.spyOn(MonotonicClockGateway.prototype, 'now').mockImplementation(() => now);
  let requests = 0;
  const server = createServer((_request, response) => {
    requests++;
    now = 125;
    response.write('data: {"model":"keepalive","choices":[]}\n\n');
    response.write(
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{"}}]}}]}\n\n'
    );
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const gateway = new OMLXGateway(`http://127.0.0.1:${(server.address() as AddressInfo).port}`);
  const stream = gateway.generateStreamEvents('local', [Message.user('hello')]);
  now = 100;
  try {
    const result = await stream.next();
    expect(result.value).toMatchObject({
      type: 'error',
      error: {
        evidence: {
          metadata: {
            time_to_first_token_ms: 25,
            first_token_kind: 'tool_call',
            request_duration_ms: 25,
          },
        },
      },
    });
    expect(requests).toBe(1);
  } finally {
    await stream.return(undefined);
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    clock.mockRestore();
  }
});

interface Provider {
  readonly name: string;
  readonly gateway: (host: string) => LlmGateway;
  readonly frame: (delta: object) => string;
  readonly terminal: string;
  readonly toolTerminal: string;
  readonly keepalive: string;
  readonly providerMetrics: object;
}
const sseFrame = (delta: object): string => {
  const wireDelta = 'thinking' in delta ? { reasoning_content: delta.thinking } : delta;
  return `data: ${JSON.stringify({ choices: [{ delta: wireDelta }] })}\n\n`;
};
const sseTerminal =
  'data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5,"time_to_first_token":0.7}}\n\ndata: [DONE]\n\n';
const providers: readonly Provider[] = [
  {
    name: 'OpenAI',
    gateway: (host) => new OpenAIGateway('test', `${host}/v1`),
    frame: sseFrame,
    terminal: sseTerminal,
    toolTerminal:
      'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n\ndata: [DONE]\n\n',
    keepalive: ': ping\n\n',
    providerMetrics: {},
  },
  {
    name: 'Ollama',
    gateway: (host) => new OllamaGateway(host),
    frame: (message) => `${JSON.stringify({ message, done: false })}\n`,
    terminal:
      '{"message":{"content":""},"done":true,"done_reason":"stop","total_duration":900,"prompt_eval_duration":200}\n',
    toolTerminal: '{"message":{"content":""},"done":true,"done_reason":"stop"}\n',
    keepalive: '\n',
    providerMetrics: { total_duration: 900, prompt_eval_duration: 200 },
  },
  {
    name: 'oMLX',
    gateway: (host) => new OMLXGateway(host),
    frame: sseFrame,
    terminal: sseTerminal,
    toolTerminal:
      'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n\ndata: [DONE]\n\n',
    keepalive: 'data: {"model":"keepalive","choices":[{"delta":{"content":"ignore"}}]}\n\n',
    providerMetrics: { usage: { time_to_first_token: 0.7 } },
  },
];

describe.each(providers)('$name capture observation timing', (provider) => {
  it('retains split-frame token timing when response capture rejects', async () => {
    const probe = await captureTimingProbe(
      provider,
      timingRoutes[1],
      { content: 'answer' },
      captureOutcomes[1].finish
    );
    const terminal = probe.observations[0];
    const recovery = requireRecovery(terminal);

    expect(probe.beforeRelease).toEqual([]);
    expect(probe.observations).toHaveLength(1);
    expect(terminal.value).toMatchObject({
      evidence: {
        metadata: {
          time_to_first_token_ms: 25,
          first_token_kind: 'content',
          request_duration_ms: 80,
        },
      },
    });
    expect(terminal.identity).toBe(recovery);
    expect(recovery.failure).toBe(recovery.history[0]);
    expect(recovery.failure.classification.reason).toBe('capture_failed');
    expect(inspectRecoveryFailure(recovery.failure)?.captureCause).toBe(probe.cause);
    expect(recovery.failure.progress.delivered.contentBytes).toBe(0);
    expect(probe.requests).toBe(1);
  });
});
const cases = [
  {
    name: 'content-first',
    delta: { content: 'answer' },
    kind: 'content',
    terminalEvent: { type: 'completed' },
  },
  {
    name: 'thinking-first',
    delta: { thinking: 'thought' },
    kind: 'thinking',
    terminalEvent: { type: 'completed' },
  },
  {
    name: 'tool-argument-first',
    delta: {
      tool_calls: [
        { index: 0, id: 't1', type: 'function', function: { name: 'lookup', arguments: '{}' } },
      ],
    },
    kind: 'tool_call',
    terminalEvent: { type: 'error' },
  },
];
async function collect<T>(stream: AsyncIterable<T>): Promise<T[]> {
  const values: T[] = [];
  for await (const value of stream) values.push(value);
  return values;
}
function eventEvidence(event: LlmStreamEvent): CompletionEvidence | undefined {
  if (event.type === 'completed') return event.metadata;
  if (event.type === 'error') return event.error.evidence;
  throw new Error('Expected terminal event');
}
function chunkEvidence(chunk: Result<StreamChunk, Error>): CompletionEvidence | undefined {
  if (chunk.ok) return chunk.value.evidence;
  throw chunk.error;
}

// Real loopback HTTP; only the monotonic clock is controlled.
describe.each(providers)('$name client stream timing', (provider) => {
  describe.each([
    {
      name: 'disabled',
      recovery: undefined,
      expectedRequests: 1,
      retryTerminal: { type: 'error' },
      retryMetrics: { request_duration_ms: 25 },
    },
    {
      name: 'enabled',
      recovery: { maxAttempts: 2, baseDelayMs: 0, admit: async () => 'allow' as const },
      expectedRequests: 2,
      retryTerminal: { type: 'completed' },
      retryMetrics: {
        request_duration_ms: 80,
        first_token_kind: 'content',
        time_to_first_token_ms: 25,
      },
    },
  ])('recovery $name', ({ recovery, expectedRequests, retryTerminal, retryMetrics }) => {
    let requests: number;
    let script: string;
    let rejectFirst: boolean;
    let followup: string | undefined;
    let disconnect: () => void;
    let clock: jest.SpyInstance;
    let gateway: LlmGateway;
    const server = createServer((_request, response) => {
      requests++;
      if (rejectFirst && requests === 1) {
        response.writeHead(503);
        response.end('{"error":"busy"}');
        return;
      }
      disconnect = () => response.destroy();
      const responseScript = requests > 1 ? (followup ?? script) : script;
      response.write(responseScript);
      if (
        responseScript.endsWith(provider.terminal) ||
        responseScript.endsWith(provider.toolTerminal)
      )
        response.end();
    });
    beforeEach(async () => {
      requests = 0;
      rejectFirst = false;
      followup = undefined;
      clock = jest
        .spyOn(MonotonicClockGateway.prototype, 'now')
        .mockReturnValueOnce(100)
        .mockReturnValueOnce(125)
        .mockReturnValue(180);
      await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
      gateway = provider.gateway(`http://127.0.0.1:${(server.address() as AddressInfo).port}`);
    });
    afterEach(async () => {
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
      clock.mockRestore();
    });

    it.each(cases)(
      'measures $name legacy chunks after keepalives and empty deltas',
      async ({ delta, kind }) => {
        script =
          provider.keepalive +
          provider.frame({ content: '' }) +
          provider.frame(delta) +
          provider.frame({ content: 'later' }) +
          provider.terminal;
        const stream = gateway.generateStream('gpt-4o', [Message.user('hello')], { recovery });

        expect(clock).not.toHaveBeenCalled();
        expect(requests).toBe(0);
        const results = await collect(stream);

        expect(chunkEvidence(results[results.length - 1])?.metadata).toMatchObject({
          time_to_first_token_ms: 25,
          first_token_kind: kind,
          request_duration_ms: 80,
          ...provider.providerMetrics,
        });
        expect(requests).toBe(1);
      }
    );

    it.each(cases)(
      'measures $name through broker terminal events',
      async ({ delta, kind, terminalEvent }) => {
        script =
          provider.keepalive +
          provider.frame({ content: '' }) +
          provider.frame(delta) +
          provider.frame({ content: 'later' }) +
          provider.terminal;
        const broker = new LlmBroker('gpt-4o', gateway);

        const events = await collect(
          broker.generateStreamEvents([Message.user('hello')], { recovery })
        );

        expect(eventEvidence(events[events.length - 1])?.metadata).toMatchObject({
          time_to_first_token_ms: 25,
          first_token_kind: kind,
          request_duration_ms: 80,
        });
        expect(events.filter((event) => event.type !== 'content')).toHaveLength(1);
        expect(events.at(-1)).toMatchObject(terminalEvent);
        expect(requests).toBe(1);
      }
    );

    it('leaves first-token fields absent on empty legacy streams', async () => {
      script = provider.keepalive + provider.frame({ content: '' }) + provider.terminal;

      const results = await collect(
        gateway.generateStream('gpt-4o', [Message.user('hello')], { recovery })
      );

      expect(chunkEvidence(results[results.length - 1])?.metadata).toMatchObject({
        request_duration_ms: 25,
      });
      expect(chunkEvidence(results[results.length - 1])?.metadata).not.toHaveProperty(
        'time_to_first_token_ms'
      );
      expect(chunkEvidence(results[results.length - 1])?.metadata).not.toHaveProperty(
        'first_token_kind'
      );
      expect(requests).toBe(1);
    });

    it('leaves first-token fields absent on empty event streams and preserves provider timing', async () => {
      script = provider.keepalive + provider.frame({ content: '' }) + provider.terminal;
      const broker = new LlmBroker('gpt-4o', gateway);

      const events = await collect(
        broker.generateStreamEvents([Message.user('hello')], { recovery })
      );

      expect(events).toHaveLength(1);
      expect(eventEvidence(events[0])?.metadata).toMatchObject({
        request_duration_ms: 25,
        ...provider.providerMetrics,
      });
      expect(eventEvidence(events[0])?.metadata).not.toHaveProperty('time_to_first_token_ms');
      expect(eventEvidence(events[0])?.metadata).not.toHaveProperty('first_token_kind');
      expect(requests).toBe(1);
    });

    it('times a rejected HTTP attempt and preserves the recovery request policy', async () => {
      rejectFirst = true;
      script = provider.frame({ content: 'answer' }) + provider.terminal;
      const broker = new LlmBroker('gpt-4o', gateway);

      const events = await collect(
        broker.generateStreamEvents([Message.user('hello')], { recovery })
      );

      expect(events.at(-1)).toMatchObject(retryTerminal);
      expect(eventEvidence(events[events.length - 1])?.metadata).toMatchObject(retryMetrics);
      expect(requests).toBe(expectedRequests);
    });

    it('does not count tool names or empty arguments as a token before event rejection', async () => {
      script = provider.frame({
        tool_calls: [{ index: 0, function: { name: 'lookup', arguments: '' } }],
      });
      const broker = new LlmBroker('gpt-4o', gateway);

      const events = await collect(
        broker.generateStreamEvents([Message.user('hello')], { recovery })
      );

      expect(events).toHaveLength(1);
      expect(events[0]).toMatchObject({ type: 'error' });
      expect(eventEvidence(events[0])?.metadata).toMatchObject({ request_duration_ms: 25 });
      expect(eventEvidence(events[0])?.metadata).not.toHaveProperty('time_to_first_token_ms');
      expect(eventEvidence(events[0])?.metadata).not.toHaveProperty('first_token_kind');
      expect(requests).toBe(1);
    });

    it('retains content timing on a broker failure without replay', async () => {
      script = provider.frame({ content: 'partial' });
      const stream = new LlmBroker('gpt-4o', gateway).generateStreamEvents(
        [Message.user('hello')],
        { recovery }
      );

      expect(await stream.next()).toMatchObject({ value: { type: 'content', text: 'partial' } });
      disconnect();
      const failed = await stream.next();

      expect(failed.value).toMatchObject({
        type: 'error',
        error: {
          evidence: {
            metadata: {
              time_to_first_token_ms: 25,
              first_token_kind: 'content',
              request_duration_ms: 80,
            },
          },
        },
      });
      expect(await stream.next()).toMatchObject({ done: true });
      expect(requests).toBe(1);
    });

    it('retains first-token evidence when a broker event request is cancelled', async () => {
      script = provider.frame({ content: 'partial' });
      const controller = new AbortController();
      const stream = new LlmBroker('gpt-4o', gateway).generateStreamEvents(
        [Message.user('hello')],
        { recovery },
        { signal: controller.signal }
      );

      expect(await stream.next()).toMatchObject({ value: { type: 'content', text: 'partial' } });
      controller.abort();

      expect(await stream.next()).toMatchObject({
        value: {
          type: 'error',
          error: {
            reason: 'cancelled',
            evidence: {
              metadata: {
                time_to_first_token_ms: 25,
                first_token_kind: 'content',
                request_duration_ms: 80,
              },
            },
          },
        },
      });
      expect(await stream.next()).toMatchObject({ done: true });
      expect(requests).toBe(1);
    });

    it('executes a completed streamed tool once and sends exactly one follow-up request', async () => {
      const calls: object[] = [];
      const tool: LlmTool = {
        name: () => 'lookup',
        matches: (name) => name === 'lookup',
        descriptor: () => ({
          type: 'function',
          function: {
            name: 'lookup',
            description: 'Look up a value',
            parameters: { type: 'object' },
          },
        }),
        run: async (args) => {
          calls.push(args);
          return Ok('found');
        },
      };
      script =
        provider.frame({
          tool_calls: [
            { index: 0, id: 't1', type: 'function', function: { name: 'lookup', arguments: '{}' } },
          ],
        }) + provider.toolTerminal;
      followup = provider.frame({ content: 'answer' }) + provider.terminal;
      const broker = new LlmBroker('gpt-4o', gateway);

      const results = await collect(
        broker.generateStream([Message.user('hello')], { recovery }, [tool])
      );

      expect(results.map(unwrap)).toEqual(['answer']);
      expect(calls).toEqual([{}]);
      expect(requests).toBe(2);
    });

    it('preserves successful session content and history', async () => {
      script = provider.frame({ content: 'answer' }) + provider.terminal;
      const session = new ChatSession(new LlmBroker('gpt-4o', gateway));

      expect(await collect(session.sendStream('hello', recovery))).toEqual(['answer']);

      expect(session.getMessages().map(({ role, content }) => ({ role, content }))).toEqual([
        { role: 'system', content: 'You are a helpful assistant.' },
        { role: 'user', content: 'hello' },
        { role: 'assistant', content: 'answer' },
      ]);
      expect(requests).toBe(1);
    });

    it('retains timing through session failure and excludes partial assistant history', async () => {
      script = provider.frame({ content: 'partial' });
      const session = new ChatSession(new LlmBroker('gpt-4o', gateway));
      const stream = session.sendStream('hello', recovery);

      expect(await stream.next()).toMatchObject({ value: 'partial' });
      disconnect();

      await expect(stream.next()).rejects.toMatchObject({
        evidence: {
          metadata: {
            time_to_first_token_ms: 25,
            first_token_kind: 'content',
            request_duration_ms: 80,
          },
        },
      });
      expect(session.getMessages().map((message) => message.role)).toEqual(['system', 'user']);
      expect(requests).toBe(1);
    });
  });
});

interface TimingObservation {
  readonly value: unknown;
  readonly terminal: boolean;
  readonly recovery?: RecoveryError;
  readonly identity?: unknown;
}
interface TimingRoute {
  readonly name: 'legacy chunks' | 'terminal events';
  readonly stream: (
    gateway: LlmGateway,
    recovery?: RecoveryOptions
  ) => AsyncIterable<TimingObservation>;
}
const timingRoutes: readonly TimingRoute[] = [
  {
    name: 'legacy chunks',
    stream: async function* (gateway, recovery) {
      for await (const result of gateway.generateStream('gpt-4o', [Message.user('hello')], {
        recovery,
      })) {
        if (!result.ok) {
          yield {
            value: result.error,
            terminal: true,
            recovery: result.error instanceof RecoveryError ? result.error : undefined,
            identity: result.error,
          };
        } else {
          yield { value: { evidence: result.value.evidence }, terminal: result.value.done };
        }
      }
    },
  },
  {
    name: 'terminal events',
    stream: async function* (gateway, recovery) {
      const broker = new LlmBroker('gpt-4o', gateway);
      for await (const event of broker.generateStreamEvents([Message.user('hello')], {
        recovery,
      })) {
        if (event.type === 'error') {
          yield {
            value: event.error,
            terminal: true,
            recovery: event.error.recovery,
            identity: event.error.detail,
          };
        } else if (event.type === 'completed') {
          yield { value: { evidence: event.metadata }, terminal: true };
        } else {
          yield { value: event, terminal: false };
        }
      }
    },
  },
];
interface Deferred {
  readonly promise: Promise<void>;
  readonly resolve: () => void;
  readonly reject: (cause: Error) => void;
}
function deferred(): Deferred {
  let resolve = (): void => undefined;
  let reject = (_cause: Error): void => undefined;
  const promise = new Promise<void>((accept, decline) => {
    resolve = accept;
    reject = decline;
  });
  return { promise, resolve, reject };
}
const captureOutcomes = [
  {
    name: 'delayed',
    finish: (pending: Deferred, _controller: AbortController, _cause: Error): void =>
      pending.resolve(),
  },
  {
    name: 'rejected',
    reason: 'capture_failed',
    recoveryOutcome: 'interrupted',
    finish: (pending: Deferred, _controller: AbortController, cause: Error): void =>
      pending.reject(cause),
  },
  {
    name: 'cancelled',
    reason: 'cancelled',
    recoveryOutcome: 'cancelled',
    finish: (_pending: Deferred, controller: AbortController, cause: Error): void =>
      controller.abort(cause),
  },
];

// The first capture acknowledges the partial frame before the server writes the rest.
// The second capture waits until the test has observed that delivery is still blocked.
async function captureTimingProbe(
  provider: Provider,
  route: TimingRoute,
  delta: object,
  finish: (pending: Deferred, controller: AbortController, cause: Error) => void
): Promise<{
  readonly observations: readonly TimingObservation[];
  readonly beforeRelease: readonly TimingObservation[];
  readonly requests: number;
  readonly cause: Error;
  readonly admitted: jest.Mock;
  readonly responseBytes: Buffer;
}> {
  let now = 100;
  let requests = 0;
  let responses = 0;
  const pending = deferred();
  const entered = deferred();
  const controller = new AbortController();
  const cause = new RangeError('private capture failure');
  const admitted = jest.fn(async () => 'allow' as const);
  const clock = jest.spyOn(MonotonicClockGateway.prototype, 'now').mockImplementation(() => now);
  const frame = provider.frame(delta);
  const split = frame.length - 4;
  const prefix = provider.keepalive + provider.frame({ content: '' }) + provider.frame({});
  let sendRemainder = (): void => undefined;
  const server = createServer((_request, response) => {
    requests++;
    now = 110;
    response.write(prefix + frame.slice(0, split));
    sendRemainder = () => {
      now = 125;
      response.end(frame.slice(split) + provider.terminal);
    };
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const gateway = provider.gateway(`http://127.0.0.1:${(server.address() as AddressInfo).port}`);
  const observations: TimingObservation[] = [];
  const consume = async (): Promise<void> => {
    for await (const observation of route.stream(gateway, {
      maxAttempts: 2,
      baseDelayMs: 0,
      signal: controller.signal,
      admit: admitted,
      onWire: async (event) => {
        if (event.direction !== 'response' || event.complete) return;
        responses++;
        if (responses === 1) {
          sendRemainder();
          return;
        }
        entered.resolve();
        await pending.promise;
      },
    }))
      observations.push(observation);
  };
  const result = consume();
  try {
    await entered.promise;
    const beforeRelease = observations.slice();
    now = 180;
    finish(pending, controller, cause);
    await result;
    return {
      observations,
      beforeRelease,
      requests,
      cause,
      admitted,
      responseBytes: Buffer.from(prefix + frame + provider.terminal),
    };
  } finally {
    controller.abort();
    pending.resolve();
    await result;
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    clock.mockRestore();
  }
}
function requireRecovery(observation: TimingObservation): RecoveryError {
  if (!observation.recovery) throw new Error('Expected a terminal recovery failure');
  return observation.recovery;
}

describe.each(providers)('$name capture milestone regressions', (provider) => {
  describe.each(timingRoutes)('$name', (route) => {
    it.each(cases)(
      'preserves $name observation time across delayed capture',
      async ({ delta, kind }) => {
        const probe = await captureTimingProbe(provider, route, delta, captureOutcomes[0].finish);
        const terminal = probe.observations.at(-1);

        expect(probe.beforeRelease).toEqual([]);
        expect(terminal?.terminal).toBe(true);
        expect(terminal?.value).toMatchObject({
          evidence: {
            metadata: {
              time_to_first_token_ms: 25,
              first_token_kind: kind,
              request_duration_ms: 80,
            },
          },
        });
        expect(probe.observations.filter((observation) => observation.terminal)).toHaveLength(1);
        expect(probe.requests).toBe(1);
        expect(probe.admitted).not.toHaveBeenCalled();
      }
    );

    describe.each(captureOutcomes.slice(1))('capture $name', (outcome) => {
      it.each(cases)('retains $name timing without delivery or retry', async ({ delta, kind }) => {
        const probe = await captureTimingProbe(provider, route, delta, outcome.finish);
        const terminal = probe.observations[0];
        const recovery = requireRecovery(terminal);

        expect(probe.beforeRelease).toEqual([]);
        expect(probe.observations).toHaveLength(1);
        expect(terminal.terminal).toBe(true);
        expect(terminal.value).toMatchObject({
          evidence: {
            metadata: {
              time_to_first_token_ms: 25,
              first_token_kind: kind,
              request_duration_ms: 80,
            },
          },
        });
        expect(recovery).toBeInstanceOf(RecoveryError);
        expect(terminal.identity).toBe(recovery);
        expect(recovery.history).toHaveLength(1);
        expect(recovery.history[0]?.classification.reason).toBe('capture_failed');
        expect(recovery.failure.progress).toBe(recovery.history[0]?.progress);
        expect(recovery.outcome).toBe(outcome.recoveryOutcome);
        expect(recovery.failure.classification.reason).toBe(outcome.reason);
        expect(inspectRecoveryFailure(recovery.failure)?.captureCause).toBe(probe.cause);
        expect(Buffer.from(inspectRecoveryFailure(recovery.failure)?.bytes ?? [])).toEqual(
          probe.responseBytes
        );
        expect(recovery.failure.progress.delivered).toEqual({
          contentBytes: 0,
          reasoningBytes: 0,
          toolFragments: 0,
          completedToolCalls: 0,
        });
        expect(JSON.stringify(terminal.value)).not.toContain('private capture failure');
        expect(probe.requests).toBe(1);
        expect(probe.admitted).not.toHaveBeenCalled();
      });
    });
  });
});

const legacyProviders = providers.filter((provider) => provider.name !== 'Ollama');
const legacyFragments = [
  {
    name: 'nonempty legacy arguments',
    delta: { function_call: { arguments: '{' } },
    metrics: { time_to_first_token_ms: 25, first_token_kind: 'tool_call' },
  },
  { name: 'empty legacy arguments', delta: { function_call: { arguments: '' } }, metrics: {} },
  { name: 'legacy name only', delta: { function_call: { name: 'lookup' } }, metrics: {} },
];
async function legacyTimingProbe(
  provider: Provider,
  route: TimingRoute,
  delta: object,
  recovery?: RecoveryOptions
): Promise<{
  readonly observations: readonly TimingObservation[];
  readonly requests: number;
}> {
  let now = 100;
  let requests = 0;
  const clock = jest.spyOn(MonotonicClockGateway.prototype, 'now').mockImplementation(() => now);
  const server = createServer((_request, response) => {
    requests++;
    now = 125;
    response.end(
      provider.keepalive +
        provider.frame({}) +
        provider.frame({ content: '' }) +
        provider.frame(delta) +
        provider.terminal
    );
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const gateway = provider.gateway(`http://127.0.0.1:${(server.address() as AddressInfo).port}`);
  try {
    return { observations: await collect(route.stream(gateway, recovery)), requests };
  } finally {
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    clock.mockRestore();
  }
}
describe.each(legacyProviders)('$name legacy function-call timing regressions', (provider) => {
  describe.each(timingRoutes)('$name', (route) => {
    describe.each([
      {
        name: 'disabled',
        recovery: undefined,
        expected: {
          'legacy chunks': { evidence: { finishReason: 'stop' } },
          'terminal events': { reason: 'unexpected_tool_calls' },
        },
      },
      {
        name: 'enabled',
        recovery: { maxAttempts: 2, baseDelayMs: 0, admit: async () => 'allow' as const },
        expected: {
          'legacy chunks': { evidence: { finishReason: 'stop' } },
          'terminal events': { reason: 'interrupted_stream', detail: expect.any(RecoveryError) },
        },
      },
    ])('recovery $name', ({ recovery, expected }) => {
      it.each(legacyFragments)(
        'measures $name without changing delivery',
        async ({ delta, metrics }) => {
          const probe = await legacyTimingProbe(provider, route, delta, recovery);

          expect(probe.observations).toHaveLength(1);
          expect(probe.observations[0].terminal).toBe(true);
          expect(probe.observations[0].value).toMatchObject(expected[route.name]);
          expect(probe.observations[0].value).toMatchObject({
            evidence: { metadata: { request_duration_ms: 25, ...metrics } },
          });
          expect(probe.requests).toBe(1);
        }
      );
      it.each(legacyFragments.slice(1))(
        'leaves first-token fields absent for $name',
        async ({ delta }) => {
          const probe = await legacyTimingProbe(provider, route, delta, recovery);

          expect(probe.observations[0].value).not.toHaveProperty(
            'evidence.metadata.time_to_first_token_ms'
          );
          expect(probe.observations[0].value).not.toHaveProperty(
            'evidence.metadata.first_token_kind'
          );
        }
      );
    });
    it.each(captureOutcomes)(
      'retains split legacy arguments through $name capture',
      async (outcome) => {
        const probe = await captureTimingProbe(
          provider,
          route,
          { function_call: { arguments: '{' } },
          outcome.finish
        );

        expect(probe.beforeRelease).toEqual([]);
        expect(probe.observations).toHaveLength(1);
        expect(probe.observations[0].value).toMatchObject({
          evidence: {
            metadata: {
              request_duration_ms: 80,
              time_to_first_token_ms: 25,
              first_token_kind: 'tool_call',
            },
          },
        });
        expect(probe.requests).toBe(1);
        expect(probe.admitted).not.toHaveBeenCalled();
      }
    );
  });
});

describe.each(providers)('$name empty capture timing regressions', (provider) => {
  describe.each(timingRoutes)('$name', (route) => {
    it.each(captureOutcomes)(
      'ignores keepalives and empty deltas through $name capture',
      async (outcome) => {
        const probe = await captureTimingProbe(provider, route, { content: '' }, outcome.finish);

        expect(probe.beforeRelease).toEqual([]);
        expect(probe.observations).toHaveLength(1);
        expect(probe.observations[0].value).toMatchObject({
          evidence: { metadata: { request_duration_ms: 80 } },
        });
        expect(probe.observations[0].value).not.toHaveProperty(
          'evidence.metadata.time_to_first_token_ms'
        );
        expect(probe.observations[0].value).not.toHaveProperty(
          'evidence.metadata.first_token_kind'
        );
        expect(probe.requests).toBe(1);
      }
    );
  });
});
