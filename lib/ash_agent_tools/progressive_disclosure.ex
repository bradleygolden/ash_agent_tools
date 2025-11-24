defmodule AshAgentTools.ProgressiveDisclosure do
  @moduledoc """
  Helper utilities for Progressive Disclosure patterns on tool results and context.
  """

  alias AshAgent.Context
  alias AshAgentTools.ResultProcessors
  alias AshAgentTools.ResultProcessors.{Sample, Summarize, Truncate}
  require Logger

  def process_tool_results(results, opts \\ []) do
    skip_small? = Keyword.get(opts, :skip_small, true)

    results
    |> maybe_skip_small(skip_small?, opts)
    |> apply_truncate(opts)
    |> apply_summarize(opts)
    |> apply_sample(opts)
    |> emit_processing_telemetry(opts)
  end

  defp maybe_skip_small(results, false, _opts), do: {:process, results}

  defp maybe_skip_small(results, true, opts) do
    truncate_threshold = Keyword.get(opts, :truncate, :infinity)

    has_large_result? =
      Enum.any?(results, fn
        {_name, {:ok, data}} ->
          ResultProcessors.estimate_size(data) > truncate_threshold

        _ ->
          false
      end)

    if has_large_result? do
      {:process, results}
    else
      Logger.debug("All results under threshold, skipping processing")
      {:skip, results}
    end
  end

  defp apply_truncate({:skip, results}, _opts), do: {:skip, results}

  defp apply_truncate({:process, results}, opts) do
    case Keyword.get(opts, :truncate) do
      nil ->
        {:process, results}

      max_size when is_integer(max_size) ->
        Logger.debug("Truncating results to max_size=#{max_size}")
        truncated = Truncate.process(results, max_size: max_size)
        {:process, truncated}
    end
  end

  defp apply_summarize({:skip, results}, _opts), do: {:skip, results}

  defp apply_summarize({:process, results}, opts) do
    summarize_opts = Keyword.get(opts, :summarize, false)

    cond do
      summarize_opts == false ->
        {:process, results}

      summarize_opts == true ->
        Logger.debug("Summarizing results with defaults")
        summarized = Summarize.process(results, [])
        {:process, summarized}

      is_list(summarize_opts) ->
        Logger.debug("Summarizing results with options: #{inspect(summarize_opts)}")
        summarized = Summarize.process(results, summarize_opts)
        {:process, summarized}
    end
  end

  defp apply_sample({:skip, results}, _opts), do: {:skip, results}

  defp apply_sample({:process, results}, opts) do
    case Keyword.get(opts, :sample) do
      nil ->
        {:process, results}

      sample_size when is_integer(sample_size) ->
        Logger.debug("Sampling results with size=#{sample_size}")
        sampled = Sample.process(results, sample_size: sample_size)
        {:process, sampled}
    end
  end

  defp emit_processing_telemetry({:skip, results}, opts) do
    :telemetry.execute(
      [:ash_agent, :progressive_disclosure, :process_results],
      %{count: length(results), skipped: true},
      %{options: opts}
    )

    results
  end

  defp emit_processing_telemetry({:process, results}, opts) do
    :telemetry.execute(
      [:ash_agent, :progressive_disclosure, :process_results],
      %{count: length(results), skipped: false},
      %{options: opts}
    )

    results
  end

  def sliding_window_compact(context, window_size) do
    Context.keep_last_iterations(context, window_size)
  end

  def token_based_compact(context, opts) do
    max_tokens = Keyword.get(opts, :max_tokens, 8_000)
    target_tokens = Keyword.get(opts, :target_tokens, div(max_tokens, 2))

    messages =
      context.iterations
      |> Enum.flat_map(& &1.messages)
      |> Enum.map(&Jason.encode!/1)

    {kept_messages, _dropped} =
      Enum.reduce(messages, {[], 0}, fn message, {acc, token_count} ->
        message_tokens = String.length(message)

        cond do
          token_count + message_tokens <= target_tokens ->
            {[message | acc], token_count + message_tokens}

          token_count <= target_tokens ->
            {[message | acc], token_count + message_tokens}

          true ->
            {acc, token_count}
        end
      end)

    pruned_messages =
      kept_messages
      |> Enum.reverse()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.map(fn msg -> Map.update(msg, "role", "user", &String.to_atom/1) end)

    pruned_iteration = %{
      number: 1,
      messages: pruned_messages,
      tool_calls: [],
      started_at: DateTime.utc_now(),
      completed_at: nil,
      metadata: %{}
    }

    Context.create!(%{iterations: [pruned_iteration], current_iteration: 1})
  end
end
