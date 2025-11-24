defmodule AshAgentTools.ContextTest do
  use ExUnit.Case, async: true

  alias AshAgentTools.Context

  describe "add_tool_results/2" do
    test "adds tool results to current iteration" do
      context = Context.new("Hello", [])

      context =
        Context.add_assistant_message(context, "Checking", [
          %{id: "call_1", name: "get_weather", arguments: %{}}
        ])

      results = [
        {"call_1", {:ok, %{temperature: 72}}}
      ]

      context = Context.add_tool_results(context, results)

      assert context.current_iteration == 1
      assert length(context.iterations) == 1

      [iteration] = context.iterations
      assert iteration.number == 1
      assert length(iteration.messages) == 3

      [_, _, result_message] = iteration.messages
      assert result_message.role == :user
      assert is_list(result_message.content)
      assert length(result_message.content) == 1

      [content_part] = result_message.content
      assert content_part.type == :tool_result
      assert content_part.tool_use_id == "call_1"
      assert is_binary(content_part.content)
    end

    test "handles tool errors" do
      context = Context.new("Hello", [])

      context =
        Context.add_assistant_message(context, "Checking", [
          %{id: "call_1", name: "get_weather", arguments: %{}}
        ])

      results = [
        {"call_1", {:error, "API unavailable"}}
      ]

      context = Context.add_tool_results(context, results)

      [iteration] = context.iterations
      [_, _, result_message] = iteration.messages
      [content_part] = result_message.content
      assert content_part.type == :tool_result
      assert is_binary(content_part.content)
    end
  end

  describe "extract_tool_calls/1" do
    test "extracts tool calls from last assistant message" do
      context = Context.new("Hello", [])
      tool_calls = [%{id: "call_1", name: "get_weather", arguments: %{}}]

      context = Context.add_assistant_message(context, "Checking", tool_calls)

      assert Context.extract_tool_calls(context) == tool_calls
    end

    test "returns empty list when no tool calls" do
      context = Context.new("Hello", [])
      context = Context.add_assistant_message(context, "No tools")

      assert Context.extract_tool_calls(context) == []
    end

    test "returns empty list when last message is not assistant" do
      context = Context.new("Hello", [])

      assert Context.extract_tool_calls(context) == []
    end
  end
end
