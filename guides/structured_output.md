# Tutorial: Extracting Structured Data

## Why Use Structured Output?

LLMs are great at generating text, but sometimes you need data in a machine-readable format like JSON. Structured output allows you to define a schema (using Ecto schemas in Elixir) and force the LLM to return data that matches that schema.

This is essential for:
- Data extraction from unstructured text
- Building API integrations
- Populating databases
- ensuring reliable downstream processing

## Getting Started

Let's build an example that extracts user information from a natural language description.

### 1. Define Your Data Schema

We use `Ecto.Schema` to define the structure we want.

```elixir
defmodule UserInfo do
  use Ecto.Schema
  use Mojentic.LLM.Schema

  @primary_key false
  embedded_schema do
    field :name, :string
    field :age, :integer
    field :interests, {:array, :string}
  end
end
```

### 2. Initialize the Broker

```elixir
alias Mojentic.LLM.Broker
alias Mojentic.LLM.Gateways.Ollama

broker = Broker.new("qwen3:32b", Ollama)
```

### 3. Generate Structured Data

Use `Broker.generate_structured/3` to request the data.

```elixir
text = "John Doe is a 30-year-old software engineer who loves hiking and reading."

{:ok, user_info} = Broker.generate_structured(broker, text, UserInfo)

IO.inspect(user_info)
# %UserInfo{
#   name: "John Doe",
#   age: 30,
#   interests: ["hiking", "reading"]
# }
```

## How It Works

1.  **Schema Definition**: Mojentic converts your Ecto schema into a JSON schema that the LLM can understand.
2.  **Prompt Engineering**: The broker automatically appends instructions to the prompt, telling the LLM to output JSON matching the schema.
3.  **Validation**: When the response comes back, Mojentic parses the JSON and casts it into your Ecto struct, performing validation (e.g., ensuring `age` is an integer).

## Advanced: Nested Schemas

You can also use nested schemas for more complex data.

```elixir
defmodule Address do
  use Ecto.Schema
  use Mojentic.LLM.Schema

  @primary_key false
  embedded_schema do
    field :street, :string
    field :city, :string
  end
end

defmodule UserProfile do
  use Ecto.Schema
  use Mojentic.LLM.Schema

  @primary_key false
  embedded_schema do
    field :name, :string
    embeds_one :address, Address
  end
end
```

## Summary

Structured output turns unstructured text into reliable data structures. By defining Ecto schemas, you can integrate LLM outputs directly into your Elixir application's logic with type safety and validation.
