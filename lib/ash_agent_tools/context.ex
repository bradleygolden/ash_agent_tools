defmodule AshAgentTools.Context do
  @moduledoc """
  Tool-aware context wrapper that extends the base AshAgent context implementation.

  This module provides additional functionality for tool-calling agents, including:
  - Tool result tracking
  - Tool call timing information
  - Tool call extraction from messages

  It delegates all base context operations to `AshAgent.Context` and adds
  tool-specific capabilities on top.

  ## Usage

  This context is automatically used when:
  1. `ash_agent_tools` is installed and started
  2. An agent has tools configured via the `tools` section

  The runtime automatically selects this context via the RuntimeRegistry.
  """

  alias AshAgent.Context

  # Delegate base context operations to AshAgent.Context
  # These functions maintain compatibility with the expected context interface

  @doc "Creates a new context. Delegates to `AshAgent.Context.new/2`."
  def new(input, opts \\ []), do: Context.new(input, opts)

  @doc "Converts context to messages. Delegates to `AshAgent.Context.to_messages/1`."
  def to_messages(ctx), do: Context.to_messages(ctx)

  @doc "Adds assistant message. Delegates to `AshAgent.Context.add_assistant_message/3`."
  def add_assistant_message(ctx, content, tool_calls \\ []),
    do: Context.add_assistant_message(ctx, content, tool_calls)

  @doc "Records LLM call timing. Delegates to `AshAgent.Context.add_llm_call_timing/1`."
  def add_llm_call_timing(ctx), do: Context.add_llm_call_timing(ctx)

  @doc "Adds token usage. Delegates to `AshAgent.Context.add_token_usage/2`."
  def add_token_usage(ctx, usage), do: Context.add_token_usage(ctx, usage)

  @doc "Gets cumulative tokens. Delegates to `AshAgent.Context.get_cumulative_tokens/1`."
  def get_cumulative_tokens(ctx), do: Context.get_cumulative_tokens(ctx)

  @doc "Checks iteration limit. Delegates to `AshAgent.Context.exceeded_max_iterations?/2`."
  def exceeded_max_iterations?(ctx, max), do: Context.exceeded_max_iterations?(ctx, max)

  @doc "Persists context updates. Delegates to `AshAgent.Context.persist/2`."
  def persist(ctx, attrs), do: Context.persist(ctx, attrs)

  def add_tool_results(ctx, results) when is_list(results) do
    result_message = %{
      role: :user,
      content: Enum.map(results, &format_result/1)
    }

    update_iteration(ctx, fn iter ->
      Map.update!(iter, :messages, &(&1 ++ [result_message]))
    end)
  end

  def update_tool_calls_timing(ctx, tool_calls_with_timing)
      when is_list(tool_calls_with_timing) do
    timings_by_id = Map.new(tool_calls_with_timing, &{&1.id, &1})

    update_iteration(ctx, fn iter ->
      updated_calls =
        Enum.map(iter.tool_calls || [], fn tool_call ->
          merge_tool_call_timing(tool_call, timings_by_id)
        end)

      Map.put(iter, :tool_calls, updated_calls)
    end)
  end

  defp merge_tool_call_timing(tool_call, timings_by_id) do
    case Map.get(timings_by_id, tool_call.id) do
      nil -> tool_call
      timing -> Map.merge(tool_call, Map.drop(timing, [:name, :arguments]))
    end
  end

  def extract_tool_calls(ctx) do
    case current_iteration(ctx) do
      %{messages: messages} ->
        case List.last(messages) do
          %{role: :assistant, tool_calls: tool_calls} when is_list(tool_calls) -> tool_calls
          _ -> []
        end

      _ ->
        []
    end
  end

  defp update_iteration(ctx, fun) do
    index = ctx.current_iteration - 1

    updated_iteration =
      ctx.iterations
      |> Enum.at(index)
      |> fun.()

    iterations = List.replace_at(ctx.iterations, index, updated_iteration)

    persist(ctx, %{iterations: iterations})
  end

  defp current_iteration(ctx), do: Enum.at(ctx.iterations, ctx.current_iteration - 1)

  defp format_result({tool_call_id, {:ok, {:halt, result}}}),
    do: build_result(tool_call_id, result)

  defp format_result({tool_call_id, {:ok, result}}),
    do: build_result(tool_call_id, result)

  defp format_result({tool_call_id, {:error, reason}}) do
    build_result(tool_call_id, %{error: format_error(reason)})
  end

  defp build_result(tool_call_id, value) do
    %{
      type: :tool_result,
      tool_use_id: tool_call_id,
      content: format_value(value)
    }
  end

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
