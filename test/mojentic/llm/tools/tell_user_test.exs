defmodule Mojentic.LLM.Tools.TellUserTest do
  use ExUnit.Case, async: true

  alias Mojentic.LLM.Tools.TellUser

  import ExUnit.CaptureIO

  describe "new/0" do
    test "creates a new TellUser instance" do
      tool = TellUser.new()
      assert %TellUser{} = tool
    end
  end

  describe "descriptor/0" do
    test "returns correct tool descriptor" do
      descriptor = TellUser.descriptor()

      assert descriptor.type == "function"
      assert descriptor.function.name == "tell_user"

      assert descriptor.function.description =~
               "Display a message to the user without expecting a response"

      # Check parameters structure
      params = descriptor.function.parameters
      assert params.type == "object"
      assert Map.has_key?(params.properties, :message)
      assert params.properties.message.type == "string"
      assert params.required == ["message"]
    end
  end

  describe "run/2" do
    test "displays message and returns success" do
      tool = TellUser.new()

      output =
        capture_io(fn ->
          result = TellUser.run(tool, %{"message" => "Test message"})
          assert {:ok, "Message delivered to user."} = result
        end)

      assert output =~ "MESSAGE FROM ASSISTANT:"
      assert output =~ "Test message"
    end

    test "handles empty message" do
      tool = TellUser.new()

      output =
        capture_io(fn ->
          result = TellUser.run(tool, %{})
          assert {:ok, "Message delivered to user."} = result
        end)

      assert output =~ "MESSAGE FROM ASSISTANT:"
    end

    test "handles multiline messages" do
      tool = TellUser.new()
      multiline_message = "Line 1\nLine 2\nLine 3"

      output =
        capture_io(fn ->
          result = TellUser.run(tool, %{"message" => multiline_message})
          assert {:ok, "Message delivered to user."} = result
        end)

      assert output =~ "MESSAGE FROM ASSISTANT:"
      assert output =~ "Line 1"
      assert output =~ "Line 2"
      assert output =~ "Line 3"
    end

    test "handles special characters in message" do
      tool = TellUser.new()
      special_message = "Special chars: @#$%^&*()"

      output =
        capture_io(fn ->
          result = TellUser.run(tool, %{"message" => special_message})
          assert {:ok, "Message delivered to user."} = result
        end)

      assert output =~ special_message
    end

    test "handles long messages" do
      tool = TellUser.new()
      long_message = String.duplicate("This is a long message. ", 50)

      output =
        capture_io(fn ->
          result = TellUser.run(tool, %{"message" => long_message})
          assert {:ok, "Message delivered to user."} = result
        end)

      assert output =~ "MESSAGE FROM ASSISTANT:"
      assert output =~ "This is a long message."
    end
  end
end
