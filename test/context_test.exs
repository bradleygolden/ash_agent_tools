defmodule AshAgentTools.ContextTest do
  use ExUnit.Case, async: true

  alias AshAgent.Message
  alias AshAgentTools.Context

  describe "add_tool_results/2" do
    test "stores tool results in assistant message metadata" do
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
      assert length(messages) == 2

      assistant_message = List.last(messages)
      assert assistant_message.role == :assistant
      assert assistant_message.metadata.tool_results != nil
      assert length(assistant_message.metadata.tool_results) == 1

      [{tool_call_id, tool_name, content}] = assistant_message.metadata.tool_results
      assert tool_call_id == "call_1"
      assert tool_name == "get_weather"
      assert content =~ "temperature"
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
      assistant_message = List.last(messages)
      assert assistant_message.role == :assistant

      [{_tool_call_id, _tool_name, content}] = assistant_message.metadata.tool_results
      assert content =~ "error"
    end
  end

  describe "to_messages/1" do
    test "converts context with tool calls and results to ReqLLM format" do
      context = Context.new([Message.user("Hello")])

      context =
        Context.add_assistant_message(context, "Checking", [
          %{id: "call_1", name: "get_weather", arguments: %{"city" => "NYC"}}
        ])

      results = [
        {"call_1", {:ok, %{temperature: 72}}}
      ]

      context = Context.add_tool_results(context, results)

      messages = Context.to_messages(context)

      assert length(messages) == 3
      [user_msg, assistant_msg, tool_msg] = messages

      assert user_msg.role == :user
      assert assistant_msg.role == :assistant
      assert assistant_msg.tool_calls != nil
      assert tool_msg.role == :tool
      assert tool_msg.tool_call_id == "call_1"
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
