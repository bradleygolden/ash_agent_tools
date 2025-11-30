defmodule AshAgentTools.ContextTest do
  use ExUnit.Case, async: true

  alias AshAgent.Message
  alias AshAgentTools.Context

  describe "add_tool_results/2" do
    test "adds tool results as user message" do
      context = Context.new([Message.user("Hello")])

      context =
        Context.add_assistant_message(context, "Checking", [
          %{id: "call_1", name: "get_weather", arguments: %{}}
        ])

      results = [
        {"call_1", {:ok, %{temperature: 72}}}
      ]

      context = Context.add_tool_results(context, results)

      messages = Context.messages(context)
      assert length(messages) == 3

      result_message = List.last(messages)
      assert result_message.role == :user
      assert is_binary(result_message.content)
      assert result_message.content =~ "call_1"
      assert result_message.content =~ "temperature"
    end

    test "handles tool errors" do
      context = Context.new([Message.user("Hello")])

      context =
        Context.add_assistant_message(context, "Checking", [
          %{id: "call_1", name: "get_weather", arguments: %{}}
        ])

      results = [
        {"call_1", {:error, "API unavailable"}}
      ]

      context = Context.add_tool_results(context, results)

      messages = Context.messages(context)
      result_message = List.last(messages)
      assert result_message.role == :user
      assert result_message.content =~ "error"
    end
  end

  describe "extract_tool_calls/1" do
    test "extracts tool calls from metadata" do
      context = Context.new([Message.user("Hello")])
      tool_calls = [%{id: "call_1", name: "get_weather", arguments: %{}}]

      context = Context.add_assistant_message(context, "Checking", tool_calls)

      assert Context.extract_tool_calls(context) == tool_calls
    end

    test "returns empty list when no tool calls" do
      context = Context.new([Message.user("Hello")])
      context = Context.add_assistant_message(context, "No tools")

      assert Context.extract_tool_calls(context) == []
    end

    test "returns empty list when context has no pending tool calls" do
      context = Context.new([Message.user("Hello")])

      assert Context.extract_tool_calls(context) == []
    end
  end

  describe "add_token_usage/2" do
    test "accumulates token usage in metadata" do
      context = Context.new([Message.user("Hello")])

      context = Context.add_token_usage(context, %{input: 100, output: 50})

      assert Context.get_cumulative_tokens(context) == %{
               input: 100,
               output: 50,
               total_tokens: 150
             }

      context = Context.add_token_usage(context, %{input: 50, output: 25})

      assert Context.get_cumulative_tokens(context) == %{
               input: 150,
               output: 75,
               total_tokens: 225
             }
    end
  end

  describe "increment_iteration/1" do
    test "increments iteration counter" do
      context = Context.new([Message.user("Hello")])

      context = Context.increment_iteration(context)
      refute Context.exceeded_max_iterations?(context, 5)

      context = Context.increment_iteration(context)
      context = Context.increment_iteration(context)
      context = Context.increment_iteration(context)
      context = Context.increment_iteration(context)
      context = Context.increment_iteration(context)

      assert Context.exceeded_max_iterations?(context, 5)
    end
  end
end
