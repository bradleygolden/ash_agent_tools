defmodule AshAgentTools.ToolTest.FallbackTool do
  defstruct []

  def schema do
    %{"name" => "fallback", "description" => "Fallback schema", "parameters" => %{}}
  end
end

defmodule AshAgentTools.ToolTest do
  use ExUnit.Case, async: true

  alias AshAgentTools.Tool

  describe "validate_implementation!/1" do
    defmodule ValidTool do
      def name, do: :valid_tool
      def description, do: "A valid tool"
      def schema, do: %{}
      def execute(_args, _context), do: {:ok, %{}}
    end

    defmodule MissingName do
      def description, do: "Missing name"
      def schema, do: %{}
      def execute(_args, _context), do: {:ok, %{}}
    end

    defmodule MissingDescription do
      def name, do: :missing_desc
      def schema, do: %{}
      def execute(_args, _context), do: {:ok, %{}}
    end

    defmodule MissingSchema do
      def name, do: :missing_schema
      def description, do: "Missing schema"
      def execute(_args, _context), do: {:ok, %{}}
    end

    defmodule MissingExecute do
      def name, do: :missing_execute
      def description, do: "Missing execute"
      def schema, do: %{}
    end

    test "returns :ok for valid tool implementation" do
      assert Tool.validate_implementation!(ValidTool) == :ok
    end

    test "raises for missing name/0" do
      assert_raise ArgumentError, ~r/must implement name\/0/, fn ->
        Tool.validate_implementation!(MissingName)
      end
    end

    test "raises for missing description/0" do
      assert_raise ArgumentError, ~r/must implement description\/0/, fn ->
        Tool.validate_implementation!(MissingDescription)
      end
    end

    test "raises for missing schema/0" do
      assert_raise ArgumentError, ~r/must implement schema\/0/, fn ->
        Tool.validate_implementation!(MissingSchema)
      end
    end

    test "raises for missing execute/2" do
      assert_raise ArgumentError, ~r/must implement execute\/2/, fn ->
        Tool.validate_implementation!(MissingExecute)
      end
    end
  end

  describe "to_json_schema/1 with Zoi schema" do
    test "generates JSON schema from Zoi input_schema" do
      tool_def = %{
        name: :test_tool,
        description: "Test tool",
        input_schema:
          Zoi.object(
            %{
              name: Zoi.string(),
              age: Zoi.integer() |> Zoi.optional()
            },
            coerce: true
          )
      }

      json_schema = Tool.to_json_schema(tool_def)

      assert json_schema["name"] == "test_tool"
      assert json_schema["description"] == "Test tool"
      assert json_schema["parameters"][:type] == :object
      assert json_schema["parameters"][:properties][:name][:type] == :string
      assert json_schema["parameters"][:properties][:age][:type] == :integer
      assert json_schema["parameters"][:required] == [:name]
    end

    test "generates minimal schema when no Zoi input_schema provided" do
      tool_def = %{
        name: :simple_tool,
        description: "Simple tool",
        input_schema: nil
      }

      json_schema = Tool.to_json_schema(tool_def)

      assert json_schema["name"] == "simple_tool"
      assert json_schema["description"] == "Simple tool"
      assert json_schema["parameters"]["type"] == "object"
      assert json_schema["parameters"]["properties"] == %{}
      assert json_schema["parameters"]["required"] == []
    end

    test "generates minimal schema when input_schema key is missing" do
      tool_def = %{
        name: :no_schema_tool,
        description: "No schema tool"
      }

      json_schema = Tool.to_json_schema(tool_def)

      assert json_schema["name"] == "no_schema_tool"
      assert json_schema["description"] == "No schema tool"
      assert json_schema["parameters"]["type"] == "object"
      assert json_schema["parameters"]["properties"] == %{}
      assert json_schema["parameters"]["required"] == []
    end

    test "handles nil description" do
      tool_def = %{
        name: :nil_desc,
        description: nil,
        input_schema: nil
      }

      json_schema = Tool.to_json_schema(tool_def)

      assert json_schema["description"] == ""
    end

    test "converts atom name to string" do
      tool_def = %{
        name: :atom_name,
        description: "Test",
        input_schema: nil
      }

      json_schema = Tool.to_json_schema(tool_def)

      assert json_schema["name"] == "atom_name"
    end

    @tag :skip
    test "includes Zoi schema descriptions" do
      # Zoi 0.11.0 does not preserve descriptions in nested object schemas
      # See: https://github.com/zachallaun/zoi/issues - consider filing an issue
      tool_def = %{
        name: :with_descriptions,
        description: "Tool with descriptions",
        input_schema:
          Zoi.object(
            %{
              query: Zoi.string(description: "Search query")
            },
            coerce: true
          )
      }

      json_schema = Tool.to_json_schema(tool_def)

      assert json_schema["parameters"][:properties][:query][:description] == "Search query"
    end

    test "handles nested Zoi types" do
      tool_def = %{
        name: :nested_tool,
        description: "Tool with nested types",
        input_schema:
          Zoi.object(
            %{
              tags: Zoi.array(Zoi.string())
            },
            coerce: true
          )
      }

      json_schema = Tool.to_json_schema(tool_def)

      assert json_schema["parameters"][:properties][:tags][:type] == :array
      assert json_schema["parameters"][:properties][:tags][:items][:type] == :string
    end

    test "includes output_schema in JSON schema when provided" do
      tool_def = %{
        name: :tool_with_output,
        description: "Tool with output schema",
        input_schema: Zoi.object(%{query: Zoi.string()}, coerce: true),
        output_schema:
          Zoi.object(%{
            results: Zoi.list(Zoi.object(%{title: Zoi.string(), url: Zoi.string()}))
          })
      }

      json_schema = Tool.to_json_schema(tool_def)

      assert json_schema["name"] == "tool_with_output"
      assert json_schema["returns"] != nil
      assert json_schema["returns"][:type] == :object
      assert json_schema["returns"][:properties][:results][:type] == :array
    end

    test "omits returns when no output_schema provided" do
      tool_def = %{
        name: :no_output_schema,
        description: "Tool without output schema",
        input_schema: nil,
        output_schema: nil
      }

      json_schema = Tool.to_json_schema(tool_def)

      refute Map.has_key?(json_schema, "returns")
    end
  end

  describe "to_json_schema/1 with module or struct" do
    defmodule SchemaOnlyTool do
      def schema do
        %{
          "name" => "schema_tool",
          "description" => "A tool with schema",
          "parameters" => %{}
        }
      end
    end

    defmodule ToSchemaTool do
      defstruct [:config]

      def to_schema(%__MODULE__{config: config}) do
        %{
          "name" => "to_schema_tool",
          "description" => "Config: #{config}",
          "parameters" => %{}
        }
      end

      def schema do
        %{
          "name" => "to_schema_tool",
          "description" => "Default",
          "parameters" => %{}
        }
      end
    end

    test "calls schema/0 for module" do
      result = Tool.to_json_schema(SchemaOnlyTool)

      assert result["name"] == "schema_tool"
    end

    test "calls to_schema/1 for struct when available" do
      tool_instance = %ToSchemaTool{config: "custom"}

      result = Tool.to_json_schema(tool_instance)

      assert result["description"] == "Config: custom"
    end

    test "falls back to schema/0 for struct when to_schema/1 not available" do
      tool_instance = %AshAgentTools.ToolTest.FallbackTool{}

      result = Tool.to_json_schema(tool_instance)

      assert result["name"] == "fallback"
    end
  end
end
