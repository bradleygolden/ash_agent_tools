defmodule AshAgentTools.Runtime.ToolExecutorTest do
  use ExUnit.Case, async: true

  alias AshAgentTools.Runtime.ToolExecutor
  alias AshAgentTools.TestDomain

  defmodule TestAgent do
    use Ash.Resource, domain: TestDomain, extensions: [AshAgent.Resource]
  end

  defmodule TestResource do
    use Ash.Resource,
      domain: TestDomain,
      data_layer: Ash.DataLayer.Ets

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, allow_nil?: false)
    end

    actions do
      defaults([:read, :create])
      default_accept([:name])
    end
  end

  describe "execute_tools/3" do
    test "executes function tools" do
      runtime_context = %{
        agent: TestAgent,
        domain: TestDomain,
        actor: nil,
        tenant: nil
      }

      tool_definitions = [
        %{
          name: :greet,
          description: "Greet someone",
          function: fn args, _context -> {:ok, %{greeting: "Hello, #{args.name}!"}} end,
          input_schema: Zoi.object(%{name: Zoi.string()}, coerce: true)
        }
      ]

      tool_calls = [
        %{id: "call_1", name: :greet, arguments: %{"name" => "Alice"}}
      ]

      results = ToolExecutor.execute_tools(tool_calls, tool_definitions, runtime_context)

      assert length(results) == 1
      {id, {status, result}} = hd(results)
      assert id == "call_1"
      assert status == :ok
      assert result.greeting == "Hello, Alice!"
    end

    test "executes Ash action tools" do
      {:ok, user} =
        TestResource
        |> Ash.Changeset.for_create(:create, %{name: "TestUser"})
        |> Ash.create()

      runtime_context = %{
        agent: TestAgent,
        domain: TestDomain,
        actor: nil,
        tenant: nil
      }

      tool_definitions = [
        %{
          name: :get_user,
          description: "Get user by name",
          action: {TestResource, :read},
          input_schema: nil
        }
      ]

      tool_calls = [
        %{id: "call_1", name: :get_user, arguments: %{}}
      ]

      results = ToolExecutor.execute_tools(tool_calls, tool_definitions, runtime_context)

      assert length(results) == 1
      {id, {status, result}} = hd(results)
      assert id == "call_1"
      assert status == :ok
      assert is_list(result)
      assert not Enum.empty?(result)
      assert hd(result).name == user.name
    end

    test "handles missing tools" do
      runtime_context = %{
        agent: TestAgent,
        domain: TestDomain,
        actor: nil,
        tenant: nil
      }

      tool_definitions = []

      tool_calls = [
        %{id: "call_1", name: :nonexistent, arguments: %{}}
      ]

      results = ToolExecutor.execute_tools(tool_calls, tool_definitions, runtime_context)

      assert length(results) == 1
      {id, {status, reason}} = hd(results)
      assert id == "call_1"
      assert status == :error
      assert reason =~ "not found"
    end

    test "handles tool execution errors" do
      runtime_context = %{
        agent: TestAgent,
        domain: TestDomain,
        actor: nil,
        tenant: nil
      }

      tool_definitions = [
        %{
          name: :error_tool,
          description: "Tool that errors",
          function: fn _args, _context -> {:error, "Something went wrong"} end,
          input_schema: nil
        }
      ]

      tool_calls = [
        %{id: "call_1", name: :error_tool, arguments: %{}}
      ]

      results = ToolExecutor.execute_tools(tool_calls, tool_definitions, runtime_context)

      assert length(results) == 1
      {id, {status, reason}} = hd(results)
      assert id == "call_1"
      assert status == :error
      assert reason == "Something went wrong"
    end

    test "validates required parameters with Zoi schema" do
      runtime_context = %{
        agent: TestAgent,
        domain: TestDomain,
        actor: nil,
        tenant: nil
      }

      tool_definitions = [
        %{
          name: :needs_param,
          description: "Needs a parameter",
          function: fn args, _context -> {:ok, args} end,
          input_schema: Zoi.object(%{required_field: Zoi.string()}, coerce: true)
        }
      ]

      tool_calls = [
        %{id: "call_1", name: :needs_param, arguments: %{}}
      ]

      results = ToolExecutor.execute_tools(tool_calls, tool_definitions, runtime_context)

      assert length(results) == 1
      {id, {status, reason}} = hd(results)
      assert id == "call_1"
      assert status == :error
      assert reason =~ "Parameter validation failed"
    end

    test "handles multiple tool calls" do
      runtime_context = %{
        agent: TestAgent,
        domain: TestDomain,
        actor: nil,
        tenant: nil
      }

      tool_definitions = [
        %{
          name: :tool1,
          description: "First tool",
          function: fn _args, _context -> {:ok, %{result: 1}} end,
          input_schema: nil
        },
        %{
          name: :tool2,
          description: "Second tool",
          function: fn _args, _context -> {:ok, %{result: 2}} end,
          input_schema: nil
        }
      ]

      tool_calls = [
        %{id: "call_1", name: :tool1, arguments: %{}},
        %{id: "call_2", name: :tool2, arguments: %{}}
      ]

      results = ToolExecutor.execute_tools(tool_calls, tool_definitions, runtime_context)

      assert length(results) == 2
      assert {"call_1", {:ok, %{result: 1}}} in results
      assert {"call_2", {:ok, %{result: 2}}} in results
    end
  end

  describe "Zoi argument validation" do
    setup do
      runtime_context = %{
        agent: TestAgent,
        domain: TestDomain,
        actor: nil,
        tenant: nil
      }

      %{runtime_context: runtime_context}
    end

    test "coerces string to integer when schema expects integer", %{
      runtime_context: runtime_context
    } do
      tool_definitions = [
        %{
          name: :count_tool,
          description: "Tool with integer param",
          function: fn args, _context -> {:ok, %{count: args.count, type: "integer"}} end,
          input_schema: Zoi.object(%{count: Zoi.integer(coerce: true)}, coerce: true)
        }
      ]

      tool_calls = [
        %{id: "call_1", name: :count_tool, arguments: %{"count" => "42"}}
      ]

      results = ToolExecutor.execute_tools(tool_calls, tool_definitions, runtime_context)

      {_id, {status, result}} = hd(results)
      assert status == :ok
      assert result.count == 42
    end

    test "returns error for value below minimum", %{runtime_context: runtime_context} do
      tool_definitions = [
        %{
          name: :age_tool,
          description: "Tool with age minimum",
          function: fn args, _context -> {:ok, args} end,
          input_schema: Zoi.object(%{age: Zoi.integer() |> Zoi.gte(0)}, coerce: true)
        }
      ]

      tool_calls = [
        %{id: "call_1", name: :age_tool, arguments: %{"age" => -5}}
      ]

      results = ToolExecutor.execute_tools(tool_calls, tool_definitions, runtime_context)

      {_id, {status, reason}} = hd(results)
      assert status == :error
      assert reason =~ "Parameter validation failed"
    end

    test "handles optional fields correctly", %{runtime_context: runtime_context} do
      tool_definitions = [
        %{
          name: :optional_tool,
          description: "Tool with optional param",
          function: fn args, _context -> {:ok, args} end,
          input_schema:
            Zoi.object(
              %{
                required_field: Zoi.string(),
                optional_field: Zoi.string() |> Zoi.optional()
              },
              coerce: true
            )
        }
      ]

      tool_calls = [
        %{id: "call_1", name: :optional_tool, arguments: %{"required_field" => "present"}}
      ]

      results = ToolExecutor.execute_tools(tool_calls, tool_definitions, runtime_context)

      {_id, {status, result}} = hd(results)
      assert status == :ok
      assert result.required_field == "present"
    end

    test "tools without schema pass args through unchanged", %{runtime_context: runtime_context} do
      tool_definitions = [
        %{
          name: :passthrough_tool,
          description: "Tool without schema",
          function: fn args, _context -> {:ok, args} end,
          input_schema: nil
        }
      ]

      tool_calls = [
        %{
          id: "call_1",
          name: :passthrough_tool,
          arguments: %{"any_key" => "any_value", "number" => 123}
        }
      ]

      results = ToolExecutor.execute_tools(tool_calls, tool_definitions, runtime_context)

      {_id, {status, result}} = hd(results)
      assert status == :ok
      assert result["any_key"] == "any_value"
      assert result["number"] == 123
    end

    test "coerces boolean from string", %{runtime_context: runtime_context} do
      tool_definitions = [
        %{
          name: :bool_tool,
          description: "Tool with boolean param",
          function: fn args, _context -> {:ok, %{enabled: args.enabled}} end,
          input_schema: Zoi.object(%{enabled: Zoi.boolean(coerce: true)}, coerce: true)
        }
      ]

      tool_calls = [
        %{id: "call_1", name: :bool_tool, arguments: %{"enabled" => "true"}}
      ]

      results = ToolExecutor.execute_tools(tool_calls, tool_definitions, runtime_context)

      {_id, {status, result}} = hd(results)
      assert status == :ok
      assert result.enabled == true
    end

    test "validates string length constraints", %{runtime_context: runtime_context} do
      tool_definitions = [
        %{
          name: :length_tool,
          description: "Tool with string length constraint",
          function: fn args, _context -> {:ok, args} end,
          input_schema: Zoi.object(%{name: Zoi.string() |> Zoi.min(3)}, coerce: true)
        }
      ]

      tool_calls = [
        %{id: "call_1", name: :length_tool, arguments: %{"name" => "ab"}}
      ]

      results = ToolExecutor.execute_tools(tool_calls, tool_definitions, runtime_context)

      {_id, {status, reason}} = hd(results)
      assert status == :error
      assert reason =~ "Parameter validation failed"
    end

    test "handles nested object schemas", %{runtime_context: runtime_context} do
      tool_definitions = [
        %{
          name: :nested_tool,
          description: "Tool with nested object",
          function: fn args, _context -> {:ok, args} end,
          input_schema:
            Zoi.object(
              %{
                user:
                  Zoi.object(
                    %{
                      name: Zoi.string(),
                      age: Zoi.integer(coerce: true)
                    },
                    coerce: true
                  )
              },
              coerce: true
            )
        }
      ]

      tool_calls = [
        %{
          id: "call_1",
          name: :nested_tool,
          arguments: %{"user" => %{"name" => "Alice", "age" => "30"}}
        }
      ]

      results = ToolExecutor.execute_tools(tool_calls, tool_definitions, runtime_context)

      {_id, {status, result}} = hd(results)
      assert status == :ok
      assert result.user.name == "Alice"
      assert result.user.age == 30
    end

    test "handles array schemas", %{runtime_context: runtime_context} do
      tool_definitions = [
        %{
          name: :array_tool,
          description: "Tool with array param",
          function: fn args, _context -> {:ok, args} end,
          input_schema: Zoi.object(%{tags: Zoi.array(Zoi.string())}, coerce: true)
        }
      ]

      tool_calls = [
        %{id: "call_1", name: :array_tool, arguments: %{"tags" => ["a", "b", "c"]}}
      ]

      results = ToolExecutor.execute_tools(tool_calls, tool_definitions, runtime_context)

      {_id, {status, result}} = hd(results)
      assert status == :ok
      assert result.tags == ["a", "b", "c"]
    end
  end
end
