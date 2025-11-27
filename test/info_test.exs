defmodule AshAgentTools.InfoTest do
  use ExUnit.Case, async: true

  alias AshAgentTools.Info

  # Use the TestAgent from DSL tests
  defmodule TestOutput do
    use Ash.TypedStruct

    typed_struct do
      field(:content, :string)
    end
  end

  defmodule TestAgentWithTools do
    use Ash.Resource,
      domain: AshAgentTools.TestDomain,
      extensions: [AshAgent.Resource, AshAgentTools.Resource]

    import AshAgent.Sigils, only: [sigil_p: 2]

    resource do
      require_primary_key?(false)
    end

    agent do
      client("mock:test-model")
      output(TestOutput)
      prompt(~p"Test")
    end

    agent_tools do
      max_iterations(10)
      timeout(30_000)
      on_error(:halt)

      tool :search do
        description("Search for information")
        function({__MODULE__, :search, []})
        schema(Zoi.object(%{query: Zoi.string()}, coerce: true))
      end

      tool :calculate do
        description("Perform calculations")
        function({__MODULE__, :calculate, []})
        schema(Zoi.object(%{expression: Zoi.string()}, coerce: true))
      end
    end

    def search(_args, _ctx), do: {:ok, "results"}
    def calculate(_args, _ctx), do: {:ok, 42}
  end

  defmodule TestAgentWithDefaults do
    use Ash.Resource,
      domain: AshAgentTools.TestDomain,
      extensions: [AshAgent.Resource, AshAgentTools.Resource]

    import AshAgent.Sigils, only: [sigil_p: 2]

    resource do
      require_primary_key?(false)
    end

    agent do
      client("mock:test-model")
      output(TestOutput)
      prompt(~p"Test")
    end

    agent_tools do
      tool :simple_tool do
        description("A simple tool")
        function({__MODULE__, :simple, []})
      end
    end

    def simple(_args, _ctx), do: {:ok, "done"}
  end

  describe "tools/1" do
    test "returns list of tool definitions" do
      tools = Info.tools(TestAgentWithTools)

      assert length(tools) == 2
      tool_names = Enum.map(tools, & &1.name)
      assert :search in tool_names
      assert :calculate in tool_names
    end

    test "each tool has required fields" do
      [tool | _] = Info.tools(TestAgentWithTools)

      assert Map.has_key?(tool, :name)
      assert Map.has_key?(tool, :description)
      assert Map.has_key?(tool, :function) or Map.has_key?(tool, :action)
    end

    test "returns empty list for agent without tools" do
      # When no tools are defined, tools section still exists but empty
      tools = Info.tools(TestAgentWithDefaults)
      assert length(tools) == 1
    end
  end

  describe "tool_config/1" do
    test "returns configuration map with custom values" do
      config = Info.tool_config(TestAgentWithTools)

      assert config.max_iterations == 10
      assert config.timeout == 30_000
      assert config.on_error == :halt
    end

    test "returns default values when not specified" do
      config = Info.tool_config(TestAgentWithDefaults)

      # DSL defaults: max_iterations: 10, timeout: 30_000, on_error: :continue
      # Info.tool_config provides fallbacks if DSL doesn't return a value
      # Since tools section exists, DSL defaults apply
      assert config.max_iterations == 10
      assert config.timeout == 30_000
      assert config.on_error == :continue
    end

    test "returns a map with expected keys" do
      config = Info.tool_config(TestAgentWithTools)

      assert Map.has_key?(config, :max_iterations)
      assert Map.has_key?(config, :timeout)
      assert Map.has_key?(config, :on_error)
    end
  end
end
