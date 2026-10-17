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
