defmodule AshAgentTools.TemplateTest do
  use ExUnit.Case, async: true

  alias AshAgentTools.DSL.Tools.ToolConfig
  alias AshAgentTools.DSL.Tools.ToolDefinition
  alias AshAgentTools.Info
  alias Spark.Dsl.Extension

  defmodule TestToolTemplate do
    use AshAgentTools.Template

    agent_tools do
      tool :search do
        description("Search for information")
        function({__MODULE__, :execute, []})

        input_schema(
          Zoi.object(
            %{
              query: Zoi.string(description: "Search query")
            },
            coerce: true
          )
        )
      end
    end

    def execute(%{query: query}, _context), do: {:ok, %{results: [query]}}
  end

  defmodule TestAgentWithToolConfig do
    use Ash.Resource,
      domain: AshAgentTools.TestDomain,
      extensions: [AshAgent.Resource, AshAgentTools.Resource]

    import AshAgent.Sigils, only: [sigil_p: 2]

    resource do
      require_primary_key?(false)
    end

    defmodule Reply do
      use Ash.TypedStruct

      typed_struct do
        field(:content, :string, allow_nil?: false)
      end
    end

    agent do
      client("mock:test-model")

      input do
        argument(:message, :string, allow_nil?: false)
      end

      output(Reply)

      prompt(~p"""
      Test prompt
      """)
    end

    agent_tools do
      tool(TestToolTemplate, config: [api_key: "test-key", max_results: 10])

      tool :inline_tool do
        description("An inline tool")
        function({__MODULE__, :inline_func, []})
      end
    end

    def inline_func(_args, _context), do: {:ok, %{result: "inline"}}
  end

  describe "tool template" do
    test "template module compiles successfully" do
      assert Code.ensure_loaded?(TestToolTemplate)
    end

    test "template exposes Spark fragment DSL state" do
      assert function_exported?(TestToolTemplate, :spark_dsl_config, 0)
    end

    test "template defines tools in fragment config" do
      config = TestToolTemplate.spark_dsl_config()
      assert is_map(config)

      agent_tools_config = config[[:agent_tools]]
      assert agent_tools_config != nil
      assert length(agent_tools_config.entities) == 1

      tool = List.first(agent_tools_config.entities)
      assert %ToolDefinition{} = tool
      assert tool.name == :search
      assert tool.description == "Search for information"
    end
  end

  describe "tool with template module" do
    test "tool template reference is stored as ToolConfig" do
      tool_configs = Info.tool_configs(TestAgentWithToolConfig)

      assert length(tool_configs) == 1

      config = List.first(tool_configs)
      assert %ToolConfig{} = config
      assert config.module == TestToolTemplate
      assert config.config == [api_key: "test-key", max_results: 10]
    end

    test "tools/1 only returns inline ToolDefinition entities" do
      tools = Info.tools(TestAgentWithToolConfig)

      assert length(tools) == 1

      tool = List.first(tools)
      assert %ToolDefinition{} = tool
      assert tool.name == :inline_tool
    end

    test "tool_configs/1 only returns ToolConfig entities from template references" do
      configs = Info.tool_configs(TestAgentWithToolConfig)

      for config <- configs do
        assert %ToolConfig{} = config
      end
    end

    test "template reference is accessible via Extension" do
      entities = Extension.get_entities(TestAgentWithToolConfig, [:agent_tools])

      tool_config = Enum.find(entities, &match?(%ToolConfig{}, &1))
      assert tool_config != nil
      assert tool_config.module == TestToolTemplate
    end
  end
end
