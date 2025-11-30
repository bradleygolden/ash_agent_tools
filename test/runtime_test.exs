defmodule AshAgentTools.RuntimeTest do
  use ExUnit.Case, async: true

  alias AshAgentTools.Runtime

  defmodule TestOutput do
    use Ash.TypedStruct

    typed_struct do
      field(:content, :string)
    end
  end

  defmodule AgentWithTools do
    use Ash.Resource,
      domain: AshAgentTools.TestDomain,
      extensions: [AshAgent.Resource, AshAgentTools.Resource]

    import AshAgent.Sigils, only: [sigil_p: 2]

    resource do
      require_primary_key?(false)
    end

    agent do
      client("mock:test-model")
      instruction(~p"Test")
      input_schema(Zoi.object(%{message: Zoi.string()}, coerce: true))
      output_schema(TestOutput)
    end

    agent_tools do
      tool :search do
        description("Search")
        function({__MODULE__, :search, []})
      end
    end

    def search(_args, _ctx), do: {:ok, "results"}
  end

  defmodule AgentWithoutTools do
    use Ash.Resource,
      domain: AshAgentTools.TestDomain,
      extensions: [AshAgent.Resource]

    import AshAgent.Sigils, only: [sigil_p: 2]

    resource do
      require_primary_key?(false)
    end

    agent do
      client("mock:test-model")
      instruction(~p"Test")
      input_schema(Zoi.object(%{message: Zoi.string()}, coerce: true))
      output_schema(TestOutput)
    end
  end

  describe "handles?/1" do
    test "returns true for agents with tools extension" do
      assert Runtime.handles?(AgentWithTools) == true
    end

    test "returns false for agents without tools extension" do
      assert Runtime.handles?(AgentWithoutTools) == false
    end

    test "returns false for non-existent modules" do
      assert Runtime.handles?(NonExistentModule) == false
    end

    test "returns false for non-agent modules" do
      assert Runtime.handles?(Kernel) == false
    end
  end
end
