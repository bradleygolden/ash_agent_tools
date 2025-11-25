defmodule AshAgentTools.ProgressiveDisclosureTest do
  use ExUnit.Case, async: true

  alias AshAgentTools.ProgressiveDisclosure

  setup do
    test_pid = self()
    ref = make_ref()

    handler_id = "test-handler-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      [:ash_agent, :progressive_disclosure, :process_results],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, handler_id: handler_id}
  end

  describe "process_tool_results/2" do
    test "returns results unchanged when all are small and skip_small is true" do
      results = [
        {"tool1", {:ok, "small data"}},
        {"tool2", {:ok, "more small data"}}
      ]

      processed = ProgressiveDisclosure.process_tool_results(results, truncate: 1000)

      assert processed == results
    end

    test "processes results when any result is large" do
      large_data = String.duplicate("x", 2000)

      results = [
        {"tool1", {:ok, large_data}},
        {"tool2", {:ok, "small"}}
      ]

      # With truncate option, large results should be truncated
      processed = ProgressiveDisclosure.process_tool_results(results, truncate: 100)

      # The large result should be truncated (100 chars + 15 char marker = ~115 bytes)
      [{"tool1", {:ok, processed_large}}, _] = processed
      # Should be much smaller than original 2000 bytes
      assert byte_size(processed_large) < 200
      assert byte_size(processed_large) < byte_size(large_data)
    end

    test "skips processing when skip_small is false" do
      results = [{"tool1", {:ok, "data"}}]

      processed = ProgressiveDisclosure.process_tool_results(results, skip_small: false)

      assert processed == results
    end

    test "applies truncate option" do
      large_data = String.duplicate("a", 500)
      results = [{"tool1", {:ok, large_data}}]

      processed =
        ProgressiveDisclosure.process_tool_results(results, truncate: 100, skip_small: false)

      [{"tool1", {:ok, truncated}}] = processed
      # Truncated is max_size (100) + marker (15 chars) = 115 bytes
      assert byte_size(truncated) < 200
      assert byte_size(truncated) < byte_size(large_data)
    end

    test "emits telemetry event with skipped: true when results are small" do
      results = [{"tool1", {:ok, "small"}}]

      ProgressiveDisclosure.process_tool_results(results, truncate: 1000)

      assert_receive {:telemetry_event, [:ash_agent, :progressive_disclosure, :process_results],
                      measurements, _metadata}

      assert measurements.skipped == true
    end

    test "emits telemetry event with skipped: false when processing occurs" do
      large_data = String.duplicate("x", 2000)
      results = [{"tool1", {:ok, large_data}}]

      ProgressiveDisclosure.process_tool_results(results, truncate: 100)

      assert_receive {:telemetry_event, [:ash_agent, :progressive_disclosure, :process_results],
                      measurements, _metadata}

      assert measurements.skipped == false
    end

    test "emits telemetry event with result count" do
      results = [
        {"tool1", {:ok, "data1"}},
        {"tool2", {:ok, "data2"}},
        {"tool3", {:ok, "data3"}}
      ]

      ProgressiveDisclosure.process_tool_results(results, truncate: 1000)

      assert_receive {:telemetry_event, [:ash_agent, :progressive_disclosure, :process_results],
                      measurements, _metadata}

      assert measurements.count == 3
    end

    test "handles error results without processing" do
      results = [
        {"tool1", {:error, "failed"}},
        {"tool2", {:ok, "small data"}}
      ]

      # Error results don't contribute to the "large" check
      processed = ProgressiveDisclosure.process_tool_results(results, truncate: 1000)

      assert processed == results
    end

    test "handles empty results" do
      results = []

      processed = ProgressiveDisclosure.process_tool_results(results)

      assert processed == []
    end
  end

  describe "sliding_window_compact/2" do
    test "keeps only last N iterations" do
      iterations = [
        %{number: 1, started_at: ~U[2025-01-01 10:00:00Z]},
        %{number: 2, started_at: ~U[2025-01-01 11:00:00Z]},
        %{number: 3, started_at: ~U[2025-01-01 12:00:00Z]},
        %{number: 4, started_at: ~U[2025-01-01 13:00:00Z]},
        %{number: 5, started_at: ~U[2025-01-01 14:00:00Z]}
      ]

      context = %AshAgent.Context{iterations: iterations}

      result = ProgressiveDisclosure.sliding_window_compact(context, 2)

      assert length(result.iterations) == 2
      assert [%{number: 4}, %{number: 5}] = result.iterations
    end

    test "keeps all iterations when window is larger" do
      iterations = [
        %{number: 1, started_at: ~U[2025-01-01 10:00:00Z]},
        %{number: 2, started_at: ~U[2025-01-01 11:00:00Z]}
      ]

      context = %AshAgent.Context{iterations: iterations}

      result = ProgressiveDisclosure.sliding_window_compact(context, 10)

      assert length(result.iterations) == 2
    end

    test "handles empty iterations" do
      context = %AshAgent.Context{iterations: []}

      result = ProgressiveDisclosure.sliding_window_compact(context, 5)

      assert result.iterations == []
    end
  end
end
