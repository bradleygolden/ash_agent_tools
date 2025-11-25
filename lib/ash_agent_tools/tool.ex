defmodule AshAgentTools.Tool do
  @moduledoc """
  Behavior and helpers for tool definitions usable by LLM providers.
  """

  @type execution_result :: {:ok, map()} | {:error, term()}

  @type context :: %{
          agent: module(),
          domain: module(),
          actor: term(),
          tenant: term()
        }

  @callback name() :: atom()
  @callback description() :: String.t()
  @callback schema() :: map()
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

  def to_json_schema(%{name: name, description: description, schema: schema})
      when not is_nil(schema) do
    json_schema = Zoi.to_json_schema(schema)

    %{
      "name" => to_string(name),
      "description" => description || "",
      "parameters" => Map.drop(json_schema, [:"$schema"])
    }
  end

  def to_json_schema(%{name: name, description: description}) do
    %{
      "name" => to_string(name),
      "description" => description || "",
      "parameters" => %{
        "type" => "object",
        "properties" => %{},
        "required" => []
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
