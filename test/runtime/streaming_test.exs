defmodule AshAgentTools.Runtime.StreamingTest do
  @moduledoc """
  Unit tests for streaming functionality in AshAgentTools.Runtime.

  These tests focus on streaming-specific behavior including:
  - Stream rejection when tools are configured
  - Stream pass-through for agents without tools
  - Hook execution during streaming
  - Telemetry emission for streams
  """
  use ExUnit.Case, async: true

  alias AshAgentTools.Runtime

  defmodule StreamOutput do
    @moduledoc false
    use Ash.TypedStruct

    typed_struct do
      field(:content, :string, allow_nil?: false)
      field(:index, :integer)
    end
  end

  defmodule StreamingMockProvider do
    @moduledoc """
    Mock provider for streaming tests.
    """
    @behaviour AshAgent.Provider

    def call(_client, _prompt, _schema, opts, _context, _tools, _messages) do
      response = Keyword.get(opts, :mock_response, %{content: "default"})
      {:ok, response}
    end

    def stream(_client, _prompt, _schema, opts, _context, _tools, _messages) do
      chunks = Keyword.get(opts, :mock_chunks, default_chunks())

      stream =
        Stream.map(chunks, fn chunk ->
          if delay = Keyword.get(opts, :mock_chunk_delay_ms) do
            Process.sleep(delay)
          end

          chunk
        end)

      {:ok, stream}
    end

    def introspect do
      %{provider: :streaming_mock, features: [:sync_call, :streaming, :tool_calling]}
    end

    defp default_chunks do
      [
        %{content: "Hello ", index: 0},
        %{content: "world!", index: 1}
      ]
    end
  end

  defmodule AgentWithToolsForStream do
    @moduledoc false
    use Ash.Resource,
      domain: AshAgentTools.Runtime.StreamingTest.TestDomain,
      extensions: [AshAgent.Resource, AshAgentTools.Resource]

    import AshAgent.Sigils, only: [sigil_p: 2]

    resource do
      require_primary_key?(false)
    end

    agent do
      provider(StreamingMockProvider)
      client(:mock)
      output(StreamOutput)
      prompt(~p"Test with tools")
    end

    tools do
      tool :search do
        description("Search for information")
        function({__MODULE__, :search, []})
      end
    end

    def search(_args, _ctx), do: {:ok, "results"}
  end

  defmodule AgentWithoutToolsForStream do
    @moduledoc false
    use Ash.Resource,
      domain: AshAgentTools.Runtime.StreamingTest.TestDomain,
      extensions: [AshAgent.Resource, AshAgentTools.Resource]

    import AshAgent.Sigils, only: [sigil_p: 2]

    resource do
      require_primary_key?(false)
    end

    agent do
      provider(:mock)

      client([
        :mock,
        mock_chunks: [
          %{content: "chunk1", index: 0},
          %{content: "chunk2", index: 1},
          %{content: "chunk3", index: 2}
        ]
      ])

      output(StreamOutput)
      prompt(~p"Test without tools")
    end
  end

  defmodule AgentWithHooksForStream do
    @moduledoc false
    use Ash.Resource,
      domain: AshAgentTools.Runtime.StreamingTest.TestDomain,
      extensions: [AshAgent.Resource, AshAgentTools.Resource]

    import AshAgent.Sigils, only: [sigil_p: 2]

    defmodule StreamHooks do
      @moduledoc false
      @behaviour AshAgent.Runtime.Hooks

      def before_call(context) do
        send(self(), {:stream_before_call, context.input})
        {:ok, context}
      end

      def after_render(context) do
        send(self(), {:stream_after_render, context.rendered_prompt})
        {:ok, context}
      end

      def after_call(context) do
        send(self(), {:stream_after_call, context.response})
        {:ok, context}
      end

      def on_error(context) do
        send(self(), {:stream_on_error, context.error})
        {:ok, context}
      end
    end

    resource do
      require_primary_key?(false)
    end

    agent do
      provider(:mock)

      client([
        :mock,
        mock_chunks: [
          %{content: "hooked", index: 0}
        ]
      ])

      output(StreamOutput)
      prompt(~p"Hooked stream")
      hooks(StreamHooks)
    end
  end

  defmodule TestDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
      resource(AgentWithToolsForStream)
      resource(AgentWithoutToolsForStream)
      resource(AgentWithHooksForStream)
    end
  end

  describe "stream/3 with tools configured" do
    test "returns error when agent has tools" do
      result = Runtime.stream(AgentWithToolsForStream, %{})

      assert {:error, error} = result
      assert error.type == :validation_error
      assert error.message =~ "Streaming with tools is not supported"
    end

    test "stream!/3 raises when agent has tools" do
      assert_raise AshAgent.Error, ~r/Streaming with tools is not supported/, fn ->
        Runtime.stream!(AgentWithToolsForStream, %{})
      end
    end
  end

  describe "stream/3 without tools" do
    test "returns ok tuple with stream when no tools configured" do
      {:ok, stream} = Runtime.stream(AgentWithoutToolsForStream, %{})

      assert is_function(stream) or is_struct(stream, Stream)
    end

    test "stream yields chunks when consumed" do
      {:ok, stream} = Runtime.stream(AgentWithoutToolsForStream, %{})

      results = Enum.to_list(stream)

      assert length(results) == 3
      assert Enum.at(results, 0).content == "chunk1"
      assert Enum.at(results, 1).content == "chunk2"
      assert Enum.at(results, 2).content == "chunk3"
    end

    test "stream converts chunks to output struct" do
      {:ok, stream} = Runtime.stream(AgentWithoutToolsForStream, %{})

      results = Enum.to_list(stream)

      assert Enum.all?(results, &match?(%StreamOutput{}, &1))
    end

    test "stream supports early termination with Enum.take" do
      {:ok, stream} = Runtime.stream(AgentWithoutToolsForStream, %{})

      results = Enum.take(stream, 2)

      assert length(results) == 2
      assert Enum.at(results, 0).content == "chunk1"
      assert Enum.at(results, 1).content == "chunk2"
    end
  end

  describe "stream!/3" do
    test "returns stream directly when successful" do
      stream = Runtime.stream!(AgentWithoutToolsForStream, %{})

      assert is_function(stream) or is_struct(stream, Stream)
    end

    test "stream! result is consumable" do
      stream = Runtime.stream!(AgentWithoutToolsForStream, %{})

      results = Enum.to_list(stream)

      assert length(results) == 3
    end
  end

  describe "stream/3 hook execution" do
    test "executes before_call hook" do
      {:ok, stream} = Runtime.stream(AgentWithHooksForStream, %{})
      _results = Enum.to_list(stream)

      assert_received {:stream_before_call, %{}}
    end

    test "executes after_render hook" do
      {:ok, stream} = Runtime.stream(AgentWithHooksForStream, %{})
      _results = Enum.to_list(stream)

      assert_received {:stream_after_render, "Hooked stream"}
    end

    test "executes after_call hook for each chunk" do
      {:ok, stream} = Runtime.stream(AgentWithHooksForStream, %{})
      _results = Enum.to_list(stream)

      # after_call is invoked during streaming for each chunk
      assert_received {:stream_after_call, %StreamOutput{content: "hooked"}}
    end
  end

  describe "stream/3 telemetry" do
    test "emits stream:start event" do
      parent = self()
      handler_id = {:tools_stream_start, make_ref()}

      :telemetry.attach(
        handler_id,
        [:ash_agent, :stream, :start],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:stream_start, metadata})
        end,
        nil
      )

      try do
        {:ok, stream} = Runtime.stream(AgentWithoutToolsForStream, %{})
        _results = Enum.to_list(stream)

        assert_receive {:stream_start, metadata}, 1_000
        assert metadata.agent == AgentWithoutToolsForStream
      after
        :telemetry.detach(handler_id)
      end
    end

    test "emits stream:chunk events" do
      parent = self()
      handler_id = {:tools_stream_chunk, make_ref()}

      :telemetry.attach(
        handler_id,
        [:ash_agent, :stream, :chunk],
        fn _event, measurements, _metadata, _ ->
          send(parent, {:stream_chunk, measurements})
        end,
        nil
      )

      try do
        {:ok, stream} = Runtime.stream(AgentWithoutToolsForStream, %{})
        _results = Enum.to_list(stream)

        assert_receive {:stream_chunk, %{index: 0}}, 1_000
        assert_receive {:stream_chunk, %{index: 1}}, 1_000
        assert_receive {:stream_chunk, %{index: 2}}, 1_000
      after
        :telemetry.detach(handler_id)
      end
    end

    test "emits stream:stop event" do
      parent = self()
      handler_id = {:tools_stream_stop, make_ref()}

      :telemetry.attach(
        handler_id,
        [:ash_agent, :stream, :stop],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:stream_stop, metadata})
        end,
        nil
      )

      try do
        {:ok, stream} = Runtime.stream(AgentWithoutToolsForStream, %{})
        _results = Enum.to_list(stream)

        assert_receive {:stream_stop, metadata}, 1_000
        assert metadata.status == :ok
      after
        :telemetry.detach(handler_id)
      end
    end

    test "emits stream:summary event with final result" do
      parent = self()
      handler_id = {:tools_stream_summary, make_ref()}

      :telemetry.attach(
        handler_id,
        [:ash_agent, :stream, :summary],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:stream_summary, metadata})
        end,
        nil
      )

      try do
        {:ok, stream} = Runtime.stream(AgentWithoutToolsForStream, %{})
        _results = Enum.to_list(stream)

        assert_receive {:stream_summary, metadata}, 1_000
        assert metadata.status == :ok
        assert %StreamOutput{} = metadata.result
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  describe "stream/3 with runtime overrides" do
    test "allows overriding client options" do
      {:ok, stream} =
        Runtime.stream(AgentWithoutToolsForStream, %{},
          client_opts: [mock_chunks: [%{content: "override", index: 0}]]
        )

      results = Enum.to_list(stream)

      assert length(results) == 1
      assert hd(results).content == "override"
    end

    test "allows overriding provider" do
      {:ok, stream} =
        Runtime.stream(AgentWithoutToolsForStream, %{},
          provider: :mock,
          client_opts: [mock_chunks: [%{content: "provider_override", index: 0}]]
        )

      results = Enum.to_list(stream)

      assert length(results) == 1
      assert hd(results).content == "provider_override"
    end
  end
end
