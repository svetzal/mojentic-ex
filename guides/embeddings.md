# Embeddings

Embeddings allow you to convert text into vector representations, which are useful for semantic search, clustering, and similarity comparisons.

## Setup

You need an embedding model. Ollama supports models like `mxbai-embed-large` or `nomic-embed-text`.

```elixir
alias Mojentic.LLM.Gateways.EmbeddingsGateway

# Initialize gateway
gateway = EmbeddingsGateway.new(model: "mxbai-embed-large")
```

## Generating Embeddings

```elixir
text = "The quick brown fox jumps over the lazy dog."
{:ok, vector} = EmbeddingsGateway.embed(gateway, text)

IO.inspect(vector)
# => [0.123, -0.456, ...]
```

## Batch Processing

You can embed multiple texts at once:

```elixir
texts = ["Hello", "World"]
{:ok, vectors} = EmbeddingsGateway.embed_batch(gateway, texts)
```

## Cosine Similarity

Mojentic provides utilities to calculate similarity between vectors:

```elixir
alias Mojentic.Math.Vector

similarity = Vector.cosine_similarity(vector1, vector2)
```
