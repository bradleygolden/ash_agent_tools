defmodule AshAgentTools.DSL.ToolsTest do
  use ExUnit.Case, async: true

  alias Spark.Dsl.Extension

  defmodule TestAgent do
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
      max_iterations(5)
      timeout(60_000)
      on_error(:continue)

      tool :test_function do
        description("A test function tool")
        function({__MODULE__, :test_func, []})

        input_schema(
          Zoi.object(
            %{
              arg1: Zoi.string(description: "First argument")
            },
            coerce: true
          )
        )
      end
    end

    def test_func(_args, _context), do: {:ok, %{result: "success"}}
  end

  describe "tools DSL" do
    test "allows defining tools section" do
      tools_config = Extension.get_opt(TestAgent, [:agent_tools], :max_iterations)
      assert tools_config == 5
    end

    test "stores tool definitions" do
      tools = Extension.get_entities(TestAgent, [:agent_tools])
      assert length(tools) == 1

      tool = List.first(tools)
      assert tool.name == :test_function
      assert tool.description == "A test function tool"
      assert tool.function == {AshAgentTools.DSL.ToolsTest.TestAgent, :test_func, []}
    end

    test "validates timeout configuration" do
      timeout = Extension.get_opt(TestAgent, [:agent_tools], :timeout)
      assert timeout == 60_000
    end

    test "validates on_error configuration" do
      on_error = Extension.get_opt(TestAgent, [:agent_tools], :on_error)
      assert on_error == :continue
    end
  end
end
