defmodule AshAgentTools.Tool do
  @moduledoc """
  Behavior and helpers for tool definitions usable by LLM providers.
  """

  @type parameter_schema :: %{
          type: :string | :integer | :number | :boolean | :object | :array,
          required: boolean(),
          description: String.t(),
          properties: map(),
          items: map()
        }

  @type schema :: %{
          name: String.t(),
          description: String.t(),
          parameters: %{
            type: :object,
            properties: %{atom() => parameter_schema()},
            required: [atom()]
          }
        }

  @type execution_result :: {:ok, map()} | {:error, term()}

  @type context :: %{
          agent: module(),
          domain: module(),
          actor: term(),
          tenant: term()
        }

  @callback name() :: atom()
  @callback description() :: String.t()
  @callback schema() :: schema()
  @callback execute(args :: map(), context :: context()) :: execution_result()

  def validate_implementation!(module) do
    unless function_exported?(module, :name, 0) do
      raise ArgumentError, "Tool #{inspect(module)} must implement name/0"
    end

    unless function_exported?(module, :description, 0) do
      raise ArgumentError, "Tool #{inspect(module)} must implement description/0"
    end

    unless function_exported?(module, :schema, 0) do
      raise ArgumentError, "Tool #{inspect(module)} must implement schema/0"
    end

    unless function_exported?(module, :execute, 2) do
      raise ArgumentError, "Tool #{inspect(module)} must implement execute/2"
    end

    :ok
  end

  def map_type_to_json_schema(:string), do: "string"
  def map_type_to_json_schema(:integer), do: "integer"
  def map_type_to_json_schema(:float), do: "number"
  def map_type_to_json_schema(:number), do: "number"
  def map_type_to_json_schema(:boolean), do: "boolean"
  def map_type_to_json_schema(:uuid), do: "string"
  def map_type_to_json_schema(:map), do: "object"
  def map_type_to_json_schema(:atom), do: "string"
  def map_type_to_json_schema({:array, _item_type}), do: "array"
  def map_type_to_json_schema(_unknown), do: "string"

  def build_property_schema(parameter) when is_map(parameter) do
    base_schema = %{
      "type" => map_type_to_json_schema(parameter[:type])
    }

    case parameter[:description] do
      nil -> base_schema
      "" -> base_schema
      description -> Map.put(base_schema, "description", description)
    end
  end

  def build_property_schema(parameter) when is_list(parameter) do
    base_schema = %{
      "type" => map_type_to_json_schema(Keyword.get(parameter, :type))
    }

    case Keyword.get(parameter, :description) do
      nil -> base_schema
      "" -> base_schema
      description -> Map.put(base_schema, "description", description)
    end
  end

  def build_properties(parameters) when is_list(parameters) do
    parameters
    |> Enum.map(fn param ->
      case param do
        {name, spec} when is_atom(name) and is_list(spec) ->
          {to_string(name), build_property_schema(Keyword.put(spec, :name, name))}

        param when is_map(param) ->
          name = to_string(param[:name])
          {name, build_property_schema(param)}
      end
    end)
    |> Map.new()
  end

  def build_properties([]), do: %{}
  def build_properties(nil), do: %{}

  def extract_required_fields(parameters) when is_list(parameters) do
    parameters
    |> Enum.filter(fn param ->
      case param do
        {_name, spec} when is_list(spec) -> Keyword.get(spec, :required, false)
        param when is_map(param) -> param[:required] == true
      end
    end)
    |> Enum.map(fn param ->
      case param do
        {name, _spec} -> to_string(name)
        param when is_map(param) -> to_string(param[:name])
      end
    end)
  end

  def extract_required_fields([]), do: []
  def extract_required_fields(nil), do: []

  def build_tool_json_schema(name, description, parameters) do
    %{
      "name" => to_string(name),
      "description" => description || "",
      "parameters" => %{
        "type" => "object",
        "properties" => build_properties(parameters),
        "required" => extract_required_fields(parameters)
      }
    }
  end

  def to_json_schema(%module{} = tool_instance) do
    if function_exported?(module, :to_schema, 1) do
      module.to_schema(tool_instance)
    else
      module.schema()
    end
  end

  def to_json_schema(module) when is_atom(module) do
    module.schema()
  end
end
