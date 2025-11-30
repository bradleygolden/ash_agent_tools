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

  @doc "Adds assistant message with tool calls, storing calls in metadata."
  def add_assistant_message(ctx, content, tool_calls) when is_list(tool_calls) do
    ctx
    |> Context.add_assistant_message(content)
    |> Context.put_metadata(:pending_tool_calls, tool_calls)
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

  @doc "Converts context to provider message format."
  def to_messages(ctx) do
    ctx.messages
    |> Enum.map(&AshAgent.Message.to_provider_format/1)
  end

  @doc "Converts context to provider format (system prompt + messages)."
  def to_provider_format(ctx) do
    Context.to_provider_format(ctx)
  end

  @doc "Adds tool results as a user message."
  def add_tool_results(ctx, results) when is_list(results) do
    formatted_results =
      results
      |> Enum.map(&format_result/1)
      |> Enum.join("\n\n")

    message = Message.user(formatted_results)
    %{ctx | messages: ctx.messages ++ [message]}
  end

  @doc "Updates tool call timing information in metadata."
  def update_tool_calls_timing(ctx, tool_calls_with_timing)
      when is_list(tool_calls_with_timing) do
    current_calls = Context.get_metadata(ctx, :tool_call_timings, [])
    Context.put_metadata(ctx, :tool_call_timings, current_calls ++ tool_calls_with_timing)
  end

  @doc "Extracts pending tool calls from metadata."
  def extract_tool_calls(ctx) do
    Context.get_metadata(ctx, :pending_tool_calls, [])
  end

  defp format_result({tool_call_id, {:ok, {:halt, result}}}),
    do: build_result(tool_call_id, result)

  defp format_result({tool_call_id, {:ok, result}}),
    do: build_result(tool_call_id, result)

  defp format_result({tool_call_id, {:error, reason}}) do
    build_result(tool_call_id, %{error: format_error(reason)})
  end

  defp build_result(tool_call_id, value) do
    "[Tool Result: #{tool_call_id}]\n#{format_value(value)}"
  end

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
