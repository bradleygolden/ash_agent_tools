defmodule AshAgentTools.ToolConverter do
  @moduledoc """
  Converts tool definitions into provider-ready JSON Schema maps.
  """

  alias AshAgentTools.Tool

  @spec to_json_schema([map()]) :: [map()]
  def to_json_schema(tool_definitions) do
    Enum.map(tool_definitions, &tool_to_json_schema/1)
  end

  defp tool_to_json_schema(%{name: name, description: description, parameters: parameters}) do
    Tool.build_tool_json_schema(name, description, normalize_parameters(parameters))
  end

  defp normalize_parameters(nil), do: []
  defp normalize_parameters([]), do: []

  defp normalize_parameters(params) when is_list(params) do
    Enum.map(params, fn
      {name, spec} when is_list(spec) ->
        {name, spec}

      param when is_map(param) ->
        {param[:name] || param["name"], Map.to_list(param)}
    end)
  end
end
