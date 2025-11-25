defmodule AshAgentTools.Runtime.ToolRuntimeIntegrationTest do
  use ExUnit.Case, async: false

  alias AshAgent.Runtime
  alias AshAgent.RuntimeRegistry
  alias Spark.Dsl.Extension, as: SparkExtension

  setup do
    RuntimeRegistry.register_tool_runtime(AshAgentTools.Runtime)
    :ok
  end

  defmodule StubProvider do
    @behaviour AshAgent.Provider

    @impl true
    def call(_client, _prompt, _schema, _opts, _context, _tools, _messages) do
      {:ok,
       %{
         tool_calls: [
           %{id: "call_1", name: "submit_answer", arguments: %{}}
         ],
         content: ""
       }}
    end

    @impl true
    def stream(_client, _prompt, _schema, _opts, _context, _tools, _messages) do
      {:error, :not_supported}
    end

    @impl true
    def introspect do
      %{
        provider: :stub,
        features: [:sync_call, :tool_calling, :schema_optional]
      }
    end
  end

  defmodule ToolAgent do
    use Ash.Resource,
      domain: AshAgentTools.TestDomain,
      extensions: [AshAgent.Resource, AshAgentTools.Resource]

    require AshAgent.Sigils
    import AshAgent.Sigils, only: [sigil_p: 2]

    defmodule Reply do
      use Ash.TypedStruct

      typed_struct do
        field(:content, :string, allow_nil?: false)
      end
    end

    resource do
      require_primary_key?(false)
    end

    agent do
      client(:stub_client)
      provider(StubProvider)
      output(Reply)
      prompt(~p"Use tools to respond.")
    end

    tools do
      tool :submit_answer do
        description("Return the final answer")
        function({__MODULE__, :submit_answer, []})
      end
    end

    def submit_answer(_args, _context), do: {:halt, %Reply{content: "done"}}
  end

  test "AshAgent.Runtime delegates to tool runtime when tools configured" do
    assert {:ok, %ToolAgent.Reply{content: "done"}} = Runtime.call(ToolAgent, %{message: "hi"})
  end

  test "Tool agents are marked as requiring the tool runtime" do
    assert SparkExtension.get_persisted(ToolAgent, :requires_tool_runtime?, false)
    assert AshAgentTools.Runtime.handles?(ToolAgent)
  end

  test "AshAgent.Runtime errors when tool runtime is missing" do
    :ets.delete(:ash_agent_runtime_registry, :tool_runtime)

    on_exit(fn ->
      RuntimeRegistry.register_tool_runtime(AshAgentTools.Runtime)
    end)

    assert {:error, %AshAgent.Error{message: message}} =
             Runtime.call(ToolAgent, %{message: "hi"})

    assert message =~ "Tool runtime not available"
  end
end
