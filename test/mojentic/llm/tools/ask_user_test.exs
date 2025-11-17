defmodule Mojentic.LLM.Tools.AskUserTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mojentic.LLM.Tools.AskUser

  describe "descriptor/0" do
    test "returns valid tool descriptor" do
      descriptor = AskUser.descriptor()

      assert descriptor.type == "function"
      assert descriptor.function.name == "ask_user"
      assert is_binary(descriptor.function.description)
      assert descriptor.function.parameters.type == "object"
      assert Map.has_key?(descriptor.function.parameters.properties, :user_request)
      assert descriptor.function.parameters.required == ["user_request"]
    end

    test "descriptor includes description for user_request parameter" do
      descriptor = AskUser.descriptor()

      user_request_prop = descriptor.function.parameters.properties.user_request
      assert user_request_prop.type == "string"
      assert is_binary(user_request_prop.description)
      assert String.length(user_request_prop.description) > 0
    end
  end

  describe "new/0" do
    test "creates a new AskUser tool instance" do
      tool = AskUser.new()
      assert %AskUser{} = tool
    end
  end

  describe "run/2" do
    test "displays prompt and returns user input" do
      args = %{"user_request" => "What is your favorite color?"}

      output =
        capture_io([input: "blue\n"], fn ->
          result = AskUser.run(AskUser.new(), args)

          send(self(), {:result, result})
        end)

      assert output =~ "I NEED YOUR HELP!"
      assert output =~ "What is your favorite color?"
      assert output =~ "Your response:"

      assert_received {:result, {:ok, "blue"}}
    end

    test "trims whitespace from user input" do
      args = %{"user_request" => "Enter a value"}

      capture_io([input: "  test value  \n"], fn ->
        result = AskUser.run(AskUser.new(), args)
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, "test value"}}
    end

    test "handles empty user_request" do
      args = %{}

      output =
        capture_io([input: "response\n"], fn ->
          result = AskUser.run(AskUser.new(), args)
          send(self(), {:result, result})
        end)

      assert output =~ "I NEED YOUR HELP!"
      assert_received {:result, {:ok, "response"}}
    end

    test "handles multi-line user input" do
      args = %{"user_request" => "Tell me something"}

      capture_io([input: "Line 1\n"], fn ->
        result = AskUser.run(AskUser.new(), args)
        send(self(), {:result, result})
      end)

      # Should only get the first line
      assert_received {:result, {:ok, "Line 1"}}
    end

    test "handles special characters in user input" do
      args = %{"user_request" => "Enter special chars"}

      capture_io([input: "test@#$%^&*()\n"], fn ->
        result = AskUser.run(AskUser.new(), args)
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, "test@#$%^&*()"}}
    end

    test "handles unicode characters in user input" do
      args = %{"user_request" => "Enter unicode"}

      capture_io([input: "Hello 世界 🌍\n"], fn ->
        result = AskUser.run(AskUser.new(), args)
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, "Hello 世界 🌍"}}
    end

    test "displays complete request message" do
      long_request = "Can you help me solve this complex problem that requires multiple steps?"
      args = %{"user_request" => long_request}

      output =
        capture_io([input: "yes\n"], fn ->
          AskUser.run(AskUser.new(), args)
        end)

      assert output =~ long_request
    end
  end
end
