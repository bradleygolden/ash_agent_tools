defmodule AshAgentTools.ToolConverterTest do
  use ExUnit.Case, async: true

  alias AshAgentTools.ToolConverter

  describe "to_json_schema/1" do
    test "converts tool definitions with Zoi input_schema to JSON Schema format" do
      tool_definitions = [
        %{
          name: :greet,
          description: "Greet someone",
          input_schema:
            Zoi.object(
              %{
                name: Zoi.string(description: "Name to greet")
              },
              coerce: true
            )
        }
      ]

      schemas = ToolConverter.to_json_schema(tool_definitions)

      assert length(schemas) == 1
      schema = hd(schemas)

      assert schema["name"] == "greet"
      assert schema["description"] == "Greet someone"
      assert schema["parameters"][:type] == :object
      assert schema["parameters"][:properties][:name][:type] == :string
      assert schema["parameters"][:required] == [:name]
    end

    test "handles tools with no input_schema" do
      tool_definitions = [
        %{
          name: :simple_tool,
          description: "A simple tool",
          input_schema: nil
        }
      ]

      schemas = ToolConverter.to_json_schema(tool_definitions)

      schema = hd(schemas)
      assert schema["name"] == "simple_tool"
      assert schema["parameters"]["properties"] == %{}
      assert schema["parameters"]["required"] == []
    end

    test "handles multiple tools" do
      tool_definitions = [
        %{
          name: :tool1,
          description: "First tool",
          input_schema: Zoi.object(%{param1: Zoi.string()}, coerce: true)
        },
        %{
          name: :tool2,
          description: "Second tool",
          input_schema: Zoi.object(%{param2: Zoi.integer() |> Zoi.optional()}, coerce: true)
        }
      ]

      schemas = ToolConverter.to_json_schema(tool_definitions)

      assert length(schemas) == 2
      assert Enum.at(schemas, 0)["name"] == "tool1"
      assert Enum.at(schemas, 1)["name"] == "tool2"
    end

    test "handles various Zoi types" do
      tool_definitions = [
        %{
          name: :complex_tool,
          description: "Complex tool",
          input_schema:
            Zoi.object(
              %{
                name: Zoi.string(description: "Name"),
                age: Zoi.integer(description: "Age") |> Zoi.optional(),
                score: Zoi.float(description: "Score") |> Zoi.optional(),
                active: Zoi.boolean(description: "Active") |> Zoi.optional(),
                id: Zoi.string(description: "ID")
              },
              coerce: true
            )
        }
      ]

      schemas = ToolConverter.to_json_schema(tool_definitions)
      schema = hd(schemas)

      assert schema["parameters"][:properties][:name][:type] == :string
      assert schema["parameters"][:properties][:age][:type] == :integer
      assert schema["parameters"][:properties][:score][:type] == :number
      assert schema["parameters"][:properties][:active][:type] == :boolean
      assert schema["parameters"][:properties][:id][:type] == :string
      assert :name in schema["parameters"][:required]
      assert :id in schema["parameters"][:required]
    end

    test "handles tools without input_schema key" do
      tool_definitions = [
        %{
          name: :no_schema,
          description: "No schema"
        }
      ]

      schemas = ToolConverter.to_json_schema(tool_definitions)

      schema = hd(schemas)
      assert schema["parameters"]["properties"] == %{}
      assert schema["parameters"]["required"] == []
    end
  end
end
