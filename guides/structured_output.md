# Structured Output Guide

Generate responses that conform to predefined JSON schemas. This ensures LLM outputs are predictable, parseable, and validated.

## Why Structured Output?

Instead of parsing free-form text:

```elixir
# Free-form (unreliable)
{:ok, response} = Broker.generate(broker, [Message.user("Describe Alice")])
# Response: "Alice is 30 years old and likes reading and coding."
# Now you need to parse this text...
```

Use structured output:

```elixir
# Structured (reliable)
schema = %{
  type: "object",
  properties: %{
    name: %{type: "string"},
    age: %{type: "integer"},
    hobbies: %{type: "array", items: %{type: "string"}}
  }
}

{:ok, person} = Broker.generate_object(broker, messages, schema)
# %{"name" => "Alice", "age" => 30, "hobbies" => ["reading", "coding"]}
# Ready to use!
```

## Basic Usage

```elixir
# Define schema
schema = %{
  type: "object",
  properties: %{
    title: %{type: "string"},
    content: %{type: "string"}
  },
  required: ["title"]
}

# Generate structured response
messages = [Message.user("Write a blog post about Elixir")]

case Broker.generate_object(broker, messages, schema) do
  {:ok, post} ->
    IO.puts("Title: #{post["title"]}")
    IO.puts("Content: #{post["content"]}")
    
  {:error, :invalid_response} ->
    Logger.error("LLM didn't return valid JSON")
end
```

## JSON Schema Types

### String

```elixir
%{
  type: "string",
  description: "A person's name",
  minLength: 1,
  maxLength: 100,
  pattern: "^[A-Z][a-z]+$"  # Capitalized name
}
```

### Number

```elixir
%{
  type: "number",  # Float
  description: "Temperature in Celsius",
  minimum: -273.15,
  maximum: 100
}

%{
  type: "integer",  # Whole number
  description: "Age in years",
  minimum: 0,
  maximum: 150
}
```

### Boolean

```elixir
%{
  type: "boolean",
  description: "Is the user active?"
}
```

### Array

```elixir
%{
  type: "array",
  description: "List of hobbies",
  items: %{type: "string"},
  minItems: 1,
  maxItems: 10
}
```

### Object

```elixir
%{
  type: "object",
  description: "Address information",
  properties: %{
    street: %{type: "string"},
    city: %{type: "string"},
    zip: %{type: "string", pattern: "^\\d{5}$"}
  },
  required: ["city"]
}
```

### Enum

```elixir
%{
  type: "string",
  description: "User role",
  enum: ["admin", "user", "guest"]
}
```

## Complete Examples

### Example 1: Person Profile

```elixir
schema = %{
  type: "object",
  properties: %{
    name: %{
      type: "string",
      description: "Full name"
    },
    age: %{
      type: "integer",
      description: "Age in years",
      minimum: 0,
      maximum: 150
    },
    email: %{
      type: "string",
      description: "Email address",
      format: "email"
    },
    hobbies: %{
      type: "array",
      description: "List of hobbies",
      items: %{type: "string"}
    },
    active: %{
      type: "boolean",
      description: "Is the account active?"
    }
  },
  required: ["name", "age"]
}

messages = [Message.user("Generate a person profile for Alice")]

{:ok, person} = Broker.generate_object(broker, messages, schema)
# %{
#   "name" => "Alice Smith",
#   "age" => 30,
#   "email" => "alice@example.com",
#   "hobbies" => ["reading", "coding", "hiking"],
#   "active" => true
# }
```

### Example 2: Sentiment Analysis

```elixir
schema = %{
  type: "object",
  properties: %{
    sentiment: %{
      type: "string",
      enum: ["positive", "negative", "neutral"]
    },
    confidence: %{
      type: "number",
      minimum: 0,
      maximum: 1
    },
    keywords: %{
      type: "array",
      items: %{type: "string"}
    }
  },
  required: ["sentiment", "confidence"]
}

text = "I absolutely love using Elixir! The functional programming model is fantastic."
messages = [Message.user("Analyze sentiment: #{text}")]

{:ok, analysis} = Broker.generate_object(broker, messages, schema)
# %{
#   "sentiment" => "positive",
#   "confidence" => 0.95,
#   "keywords" => ["love", "fantastic", "functional"]
# }
```

### Example 3: Product Extraction

```elixir
schema = %{
  type: "object",
  properties: %{
    products: %{
      type: "array",
      items: %{
        type: "object",
        properties: %{
          name: %{type: "string"},
          price: %{type: "number"},
          category: %{
            type: "string",
            enum: ["electronics", "clothing", "food", "other"]
          }
        },
        required: ["name", "price"]
      }
    },
    total: %{
      type: "number",
      description: "Total price"
    }
  },
  required: ["products"]
}

text = """
I bought a laptop for $1200 and a t-shirt for $25.
Also got some coffee for $5.
"""

messages = [Message.user("Extract products: #{text}")]

{:ok, result} = Broker.generate_object(broker, messages, schema)
# %{
#   "products" => [
#     %{"name" => "laptop", "price" => 1200, "category" => "electronics"},
#     %{"name" => "t-shirt", "price" => 25, "category" => "clothing"},
#     %{"name" => "coffee", "price" => 5, "category" => "food"}
#   ],
#   "total" => 1230
# }
```

### Example 4: Classification

```elixir
schema = %{
  type: "object",
  properties: %{
    category: %{
      type: "string",
      enum: ["bug", "feature", "question", "documentation"]
    },
    priority: %{
      type: "string",
      enum: ["low", "medium", "high", "critical"]
    },
    tags: %{
      type: "array",
      items: %{type: "string"}
    }
  },
  required: ["category", "priority"]
}

issue = "The login page crashes when I enter my email. This is blocking users."
messages = [Message.user("Classify issue: #{issue}")]

{:ok, classification} = Broker.generate_object(broker, messages, schema)
# %{
#   "category" => "bug",
#   "priority" => "critical",
#   "tags" => ["login", "crash", "blocker"]
# }
```

## Nested Objects

Complex schemas with nested structures:

```elixir
schema = %{
  type: "object",
  properties: %{
    user: %{
      type: "object",
      properties: %{
        name: %{type: "string"},
        contact: %{
          type: "object",
          properties: %{
            email: %{type: "string"},
            phone: %{type: "string"}
          }
        }
      }
    },
    orders: %{
      type: "array",
      items: %{
        type: "object",
        properties: %{
          id: %{type: "string"},
          amount: %{type: "number"},
          items: %{
            type: "array",
            items: %{type: "string"}
          }
        }
      }
    }
  }
}
```

## Working with Results

### Pattern Matching

```elixir
case Broker.generate_object(broker, messages, schema) do
  {:ok, %{"sentiment" => "positive", "confidence" => conf}} when conf > 0.8 ->
    # High confidence positive
    
  {:ok, %{"sentiment" => sentiment}} ->
    # Other sentiments
    
  {:error, :invalid_response} ->
    # LLM didn't follow schema
end
```

### Validation

```elixir
defp validate_result(result) do
  with {:ok, name} <- Map.fetch(result, "name"),
       {:ok, age} <- Map.fetch(result, "age"),
       true <- is_binary(name) and is_integer(age) do
    {:ok, result}
  else
    _ -> {:error, :validation_failed}
  end
end
```

### Transformation

```elixir
def parse_person(result) do
  %Person{
    name: result["name"],
    age: result["age"],
    email: result["email"],
    hobbies: result["hobbies"] || []
  }
end

{:ok, result} = Broker.generate_object(broker, messages, schema)
person = parse_person(result)
```

## Error Handling

```elixir
case Broker.generate_object(broker, messages, schema, config) do
  {:ok, result} ->
    # Success - result matches schema
    process(result)
    
  {:error, :invalid_response} ->
    # LLM didn't return valid JSON matching schema
    Logger.error("Invalid schema response")
    use_fallback()
    
  {:error, {:gateway_error, msg}} ->
    # Gateway/network error
    Logger.error("Gateway error: #{msg}")
    retry()
    
  {:error, reason} ->
    # Other errors
    Logger.error("Error: #{inspect(reason)}")
    handle_error(reason)
end
```

## Best Practices

### 1. Keep Schemas Simple

Start with basic schemas:

```elixir
# Good: Simple, focused
schema = %{
  type: "object",
  properties: %{
    answer: %{type: "string"},
    confidence: %{type: "number"}
  }
}

# Avoid: Too complex initially
schema = %{
  type: "object",
  properties: %{
    # 20+ nested properties...
  }
}
```

### 2. Use Descriptions

Help the LLM understand expectations:

```elixir
%{
  type: "string",
  description: "User's email address in format: user@domain.com"
}
```

### 3. Mark Required Fields

Specify which fields are mandatory:

```elixir
%{
  type: "object",
  properties: %{
    id: %{type: "string"},
    name: %{type: "string"},
    optional_field: %{type: "string"}
  },
  required: ["id", "name"]
}
```

### 4. Use Enums for Fixed Options

Constrain possible values:

```elixir
%{
  type: "string",
  enum: ["small", "medium", "large"]
}
```

### 5. Provide Examples in System Messages

```elixir
system_msg = Message.system("""
You are a data extraction assistant. 
Always return data in the exact format specified.

Example:
{
  "name": "John Doe",
  "age": 30
}
""")

messages = [system_msg, Message.user("Extract: ...")]
```

## Gateway Support

Not all gateways support structured output the same way:

| Gateway | Structured Output | Notes |
|---------|------------------|-------|
| Ollama | ✅ Yes | Uses `format` parameter |
| OpenAI | 📝 Planned | Uses response_format |
| Anthropic | 📝 Planned | Uses structured prompts |

## Advanced Patterns

### Iterative Refinement

```elixir
defmodule SchemaGenerator do
  def generate_with_validation(broker, messages, schema, max_attempts \\ 3) do
    case Broker.generate_object(broker, messages, schema) do
      {:ok, result} ->
        case validate_business_rules(result) do
          :ok -> {:ok, result}
          {:error, reason} when max_attempts > 1 ->
            # Add feedback and retry
            feedback = Message.user("Fix: #{reason}")
            generate_with_validation(
              broker,
              messages ++ [feedback],
              schema,
              max_attempts - 1
            )
          {:error, reason} ->
            {:error, {:validation_failed, reason}}
        end
        
      error ->
        error
    end
  end
end
```

### Schema Composition

```elixir
defmodule Schemas do
  def person_schema do
    %{
      type: "object",
      properties: %{
        name: %{type: "string"},
        age: %{type: "integer"}
      }
    }
  end
  
  def team_schema do
    %{
      type: "object",
      properties: %{
        team_name: %{type: "string"},
        members: %{
          type: "array",
          items: person_schema()
        }
      }
    }
  end
end
```

## See Also

- [Getting Started](getting_started.html)
- [Broker Guide](broker.html)
- [Broker.generate_object/4](Mojentic.LLM.Broker.html#generate_object/4)
