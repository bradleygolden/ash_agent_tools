defmodule AshAgentTools.ToolTest.FallbackTool do
  defstruct []

  def schema do
    %{"name" => "fallback", "description" => "Fallback schema", "parameters" => %{}}
  end
end

defmodule AshAgentTools.ToolTest do
  use ExUnit.Case, async: true

  alias AshAgentTools.Tool

  describe "map_type_to_json_schema/1" do
    test "maps :string to \"string\"" do
      assert Tool.map_type_to_json_schema(:string) == "string"
    end

    test "maps :integer to \"integer\"" do
      assert Tool.map_type_to_json_schema(:integer) == "integer"
    end

    test "maps :float to \"number\"" do
      assert Tool.map_type_to_json_schema(:float) == "number"
    end

    test "maps :number to \"number\"" do
      assert Tool.map_type_to_json_schema(:number) == "number"
    end

    test "maps :boolean to \"boolean\"" do
      assert Tool.map_type_to_json_schema(:boolean) == "boolean"
    end

    test "maps :uuid to \"string\"" do
      assert Tool.map_type_to_json_schema(:uuid) == "string"
    end

    test "maps :map to \"object\"" do
      assert Tool.map_type_to_json_schema(:map) == "object"
    end

    test "maps :atom to \"string\"" do
      assert Tool.map_type_to_json_schema(:atom) == "string"
    end

    test "maps {:array, type} to \"array\"" do
      assert Tool.map_type_to_json_schema({:array, :string}) == "array"
      assert Tool.map_type_to_json_schema({:array, :integer}) == "array"
    end

    test "maps unknown types to \"string\" as fallback" do
      assert Tool.map_type_to_json_schema(:unknown_type) == "string"
      assert Tool.map_type_to_json_schema(:custom) == "string"
    end
  end

  describe "build_property_schema/1 with map input" do
    test "creates schema with type" do
      parameter = %{type: :string}

      result = Tool.build_property_schema(parameter)

      assert result == %{"type" => "string"}
    end

    test "creates schema with type and description" do
      parameter = %{type: :string, description: "The user's name"}

      result = Tool.build_property_schema(parameter)

      assert result == %{"type" => "string", "description" => "The user's name"}
    end

    test "does not include description when nil" do
      parameter = %{type: :integer, description: nil}

      result = Tool.build_property_schema(parameter)

      assert result == %{"type" => "integer"}
    end

    test "does not include description when empty string" do
      parameter = %{type: :boolean, description: ""}

      result = Tool.build_property_schema(parameter)

      assert result == %{"type" => "boolean"}
    end
  end

  describe "build_property_schema/1 with keyword list input" do
    test "creates schema with type" do
      parameter = [type: :string]

      result = Tool.build_property_schema(parameter)

      assert result == %{"type" => "string"}
    end

    test "creates schema with type and description" do
      parameter = [type: :integer, description: "A positive number"]

      result = Tool.build_property_schema(parameter)

      assert result == %{"type" => "integer", "description" => "A positive number"}
    end

    test "does not include description when nil" do
      parameter = [type: :number, description: nil]

      result = Tool.build_property_schema(parameter)

      assert result == %{"type" => "number"}
    end

    test "does not include description when empty string" do
      parameter = [type: :map, description: ""]

      result = Tool.build_property_schema(parameter)

      assert result == %{"type" => "object"}
    end
  end

  describe "build_properties/1" do
    test "returns empty map for empty list" do
      assert Tool.build_properties([]) == %{}
    end

    test "returns empty map for nil" do
      assert Tool.build_properties(nil) == %{}
    end

    test "builds properties from keyword list format" do
      parameters = [
        {:name, [type: :string, description: "User name"]},
        {:age, [type: :integer, description: "User age"]}
      ]

      result = Tool.build_properties(parameters)

      assert result == %{
               "name" => %{"type" => "string", "description" => "User name"},
               "age" => %{"type" => "integer", "description" => "User age"}
             }
    end

    test "builds properties from map format" do
      parameters = [
        %{name: :query, type: :string, description: "Search query"},
        %{name: :limit, type: :integer, description: "Max results"}
      ]

      result = Tool.build_properties(parameters)

      assert result == %{
               "query" => %{"type" => "string", "description" => "Search query"},
               "limit" => %{"type" => "integer", "description" => "Max results"}
             }
    end

    test "converts atom names to strings" do
      parameters = [{:my_param, [type: :string]}]

      result = Tool.build_properties(parameters)

      assert Map.has_key?(result, "my_param")
    end
  end

  describe "extract_required_fields/1" do
    test "returns empty list for empty input" do
      assert Tool.extract_required_fields([]) == []
    end

    test "returns empty list for nil" do
      assert Tool.extract_required_fields(nil) == []
    end

    test "extracts required fields from keyword list format" do
      parameters = [
        {:name, [type: :string, required: true]},
        {:age, [type: :integer, required: false]},
        {:email, [type: :string, required: true]}
      ]

      result = Tool.extract_required_fields(parameters)

      assert result == ["name", "email"]
    end

    test "extracts required fields from map format" do
      parameters = [
        %{name: :query, type: :string, required: true},
        %{name: :limit, type: :integer, required: false},
        %{name: :offset, type: :integer, required: true}
      ]

      result = Tool.extract_required_fields(parameters)

      assert result == ["query", "offset"]
    end

    test "defaults to not required when required key is missing" do
      parameters = [
        {:name, [type: :string]},
        {:age, [type: :integer, required: true]}
      ]

      result = Tool.extract_required_fields(parameters)

      assert result == ["age"]
    end

    test "converts atom names to strings" do
      parameters = [{:my_param, [type: :string, required: true]}]

      result = Tool.extract_required_fields(parameters)

      assert result == ["my_param"]
    end
  end

  describe "build_tool_json_schema/3" do
    test "builds complete JSON schema" do
      name = :search
      description = "Search for items"

      parameters = [
        {:query, [type: :string, required: true, description: "Search query"]},
        {:limit, [type: :integer, required: false, description: "Max results"]}
      ]

      result = Tool.build_tool_json_schema(name, description, parameters)

      assert result == %{
               "name" => "search",
               "description" => "Search for items",
               "parameters" => %{
                 "type" => "object",
                 "properties" => %{
                   "query" => %{"type" => "string", "description" => "Search query"},
                   "limit" => %{"type" => "integer", "description" => "Max results"}
                 },
                 "required" => ["query"]
               }
             }
    end

    test "handles atom name conversion" do
      result = Tool.build_tool_json_schema(:my_tool, "A tool", [])

      assert result["name"] == "my_tool"
    end

    test "handles string name" do
      result = Tool.build_tool_json_schema("my_tool", "A tool", [])

      assert result["name"] == "my_tool"
    end

    test "handles nil description" do
      result = Tool.build_tool_json_schema(:tool, nil, [])

      assert result["description"] == ""
    end

    test "handles empty parameters" do
      result = Tool.build_tool_json_schema(:tool, "desc", [])

      assert result["parameters"] == %{
               "type" => "object",
               "properties" => %{},
               "required" => []
             }
    end

    test "handles nil parameters" do
      result = Tool.build_tool_json_schema(:tool, "desc", nil)

      assert result["parameters"] == %{
               "type" => "object",
               "properties" => %{},
               "required" => []
             }
    end
  end

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

  describe "to_json_schema/1" do
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
