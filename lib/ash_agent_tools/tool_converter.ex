defmodule AshAgentTools.ToolConverter do
  @moduledoc """
  Converts tool definitions into provider-ready JSON Schema maps.
  """

  alias AshAgentTools.Tool

  def to_json_schema(tool_definitions) do
    Enum.map(tool_definitions, &Tool.to_json_schema/1)
  end
end
