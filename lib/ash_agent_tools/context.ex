defmodule AshAgentTools.Context do
  @moduledoc """
  Tool-aware context wrapper that extends the base AshAgent context implementation.

  This module provides additional functionality for tool-calling agents, including:
  - Tool result tracking
  - Tool call timing information
  - Tool call extraction from messages

  It delegates all base context operations to `AshAgent.Context` and adds
  tool-specific capabilities on top using metadata.
  """

  alias AshAgent.Context
  alias AshAgent.Message

  @doc "Creates a new context. Delegates to `AshAgent.Context.new/2`."
  def new(messages, opts \\ []) when is_list(messages) do
    Context.new(messages, opts)
  end

  @doc "Returns the messages list from context."
  def messages(ctx), do: Context.messages(ctx)

  @doc "Adds assistant message. Delegates to `AshAgent.Context.add_assistant_message/2`."
  def add_assistant_message(ctx, content) do
    Context.add_assistant_message(ctx, content)
  end

  @doc "Adds assistant message with tool calls, storing calls in message metadata."
  def add_assistant_message(ctx, content, tool_calls) when is_list(tool_calls) do
    message = Message.assistant(content, %{tool_calls: tool_calls})
    %{ctx | messages: ctx.messages ++ [message]}
  end

  @doc "Records LLM call timing in metadata."
  def add_llm_call_timing(ctx) do
    Context.put_metadata(ctx, :llm_call_at, DateTime.utc_now())
  end

  @doc "Adds token usage to metadata."
  def add_token_usage(ctx, usage) do
    current = Context.get_metadata(ctx, :token_usage, %{input: 0, output: 0})

    updated = %{
      input: Map.get(current, :input, 0) + Map.get(usage, :input, 0),
      output: Map.get(current, :output, 0) + Map.get(usage, :output, 0)
    }

    Context.put_metadata(ctx, :token_usage, updated)
  end

  @doc "Gets cumulative tokens from metadata."
  def get_cumulative_tokens(ctx) do
    usage = Context.get_metadata(ctx, :token_usage, %{input: 0, output: 0})
    input_tokens = Map.get(usage, :input, 0)
    output_tokens = Map.get(usage, :output, 0)

    %{
      input: input_tokens,
      output: output_tokens,
      total_tokens: input_tokens + output_tokens
    }
  end

  @doc "Checks if iterations exceeded limit based on metadata."
  def exceeded_max_iterations?(ctx, max) do
    iteration = Context.get_metadata(ctx, :iteration, 1)
    iteration > max
  end

  @doc "Increments the iteration counter in metadata."
  def increment_iteration(ctx) do
    current = Context.get_metadata(ctx, :iteration, 0)
    Context.put_metadata(ctx, :iteration, current + 1)
  end

  @doc "Gets the current iteration number from metadata."
  def current_iteration(ctx) do
    Context.get_metadata(ctx, :iteration, 1)
  end

  @doc """
  Converts context to ReqLLM message format for tool-calling.

  This builds proper ReqLLM.Message structs including:
  - Assistant messages with tool_calls (from message metadata)
  - Tool result messages with tool_call_id (inserted after assistant messages)

  The tool results are properly interleaved - each tool result follows
  immediately after the assistant message that requested it.
  """
  def to_messages(ctx) do
    ctx.messages
    |> Enum.flat_map(&convert_message/1)
  end

  defp convert_message(%Message{role: :system, content: content}) do
    [ReqLLM.Context.system(format_content(content))]
  end

  defp convert_message(%Message{role: :user, content: content}) do
    [ReqLLM.Context.user(format_content(content))]
  end

  defp convert_message(%Message{role: :assistant, content: content, metadata: metadata}) do
    content_str = format_content(content)
    tool_calls = get_tool_calls_from_metadata(metadata)
    tool_results = get_tool_results_from_metadata(metadata)

    if tool_calls != [] do
      req_tool_calls = Enum.map(tool_calls, &to_req_llm_tool_call/1)
      assistant_msg = ReqLLM.Context.assistant(content_str, tool_calls: req_tool_calls)

      tool_result_msgs =
        Enum.map(tool_results, fn {tool_call_id, tool_name, result_content} ->
          ReqLLM.Context.tool_result_message(tool_name, tool_call_id, result_content)
        end)

      [assistant_msg | tool_result_msgs]
    else
      [ReqLLM.Context.assistant(content_str)]
    end
  end

  defp get_tool_calls_from_metadata(nil), do: []
  defp get_tool_calls_from_metadata(%{tool_calls: calls}) when is_list(calls), do: calls
  defp get_tool_calls_from_metadata(_), do: []

  defp get_tool_results_from_metadata(nil), do: []
  defp get_tool_results_from_metadata(%{tool_results: results}) when is_list(results), do: results
  defp get_tool_results_from_metadata(_), do: []

  defp to_req_llm_tool_call(%{id: id, name: name, arguments: args}) do
    args_json = if is_binary(args), do: args, else: Jason.encode!(args)
    ReqLLM.ToolCall.new(id, to_string(name), args_json)
  end

  defp format_content(content) when is_binary(content), do: content
  defp format_content(content) when is_map(content), do: Jason.encode!(content)
  defp format_content(content) when is_list(content), do: Jason.encode!(content)
  defp format_content(nil), do: ""

  @doc "Converts context to provider format (system prompt + messages)."
  def to_provider_format(ctx) do
    Context.to_provider_format(ctx)
  end

  @doc """
  Adds tool results to the last assistant message that has tool calls.

  Tool results are stored in the message's metadata alongside the tool calls,
  so they can be properly interleaved when converting to provider format.
  """
  def add_tool_results(ctx, results) when is_list(results) do
    messages = ctx.messages
    last_idx = find_last_assistant_with_tool_calls_index(messages)

    if last_idx do
      updated_messages = update_message_with_tool_results(messages, last_idx, results)
      %{ctx | messages: updated_messages}
    else
      ctx
    end
  end

  defp find_last_assistant_with_tool_calls_index(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {msg, idx} ->
      if msg.role == :assistant and
           msg.metadata != nil and
           Map.get(msg.metadata, :tool_calls, []) != [] do
        idx
      else
        nil
      end
    end)
  end

  defp update_message_with_tool_results(messages, idx, results) do
    List.update_at(messages, idx, fn msg ->
      attach_tool_results_to_message(msg, results)
    end)
  end

  defp attach_tool_results_to_message(msg, results) do
    tool_calls = get_tool_calls_from_metadata(msg.metadata)

    formatted_results =
      Enum.map(results, fn {tool_call_id, result} ->
        format_single_tool_result(tool_call_id, result, tool_calls)
      end)

    updated_metadata = Map.put(msg.metadata || %{}, :tool_results, formatted_results)
    %{msg | metadata: updated_metadata}
  end

  defp format_single_tool_result(tool_call_id, result, tool_calls) do
    tool_call = Enum.find(tool_calls, &(&1.id == tool_call_id))
    tool_name = if tool_call, do: to_string(tool_call.name), else: "unknown"
    content = format_tool_result(result)
    {tool_call_id, tool_name, content}
  end

  defp format_tool_result({:ok, value}), do: format_value(value)
  defp format_tool_result({:halt, value}), do: format_value(value)
  defp format_tool_result({:error, reason}), do: Jason.encode!(%{error: format_error(reason)})

  defp format_value(value) when is_binary(value), do: value

  defp format_value(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Jason.encode!()
  end

  defp format_value(value), do: Jason.encode!(value)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  @doc "Updates tool call timing information in metadata."
  def update_tool_calls_timing(ctx, tool_calls_with_timing)
      when is_list(tool_calls_with_timing) do
    current_calls = Context.get_metadata(ctx, :tool_call_timings, [])
    Context.put_metadata(ctx, :tool_call_timings, current_calls ++ tool_calls_with_timing)
  end

  @doc "Extracts pending tool calls from the last assistant message metadata."
  def extract_tool_calls(ctx) do
    case find_last_assistant_with_tool_calls(ctx) do
      nil -> []
      msg -> get_tool_calls_from_metadata(msg.metadata)
    end
  end

  defp find_last_assistant_with_tool_calls(ctx) do
    ctx.messages
    |> Enum.reverse()
    |> Enum.find(fn msg ->
      msg.role == :assistant and
        msg.metadata != nil and
        Map.get(msg.metadata, :tool_calls, []) != []
    end)
  end
end
