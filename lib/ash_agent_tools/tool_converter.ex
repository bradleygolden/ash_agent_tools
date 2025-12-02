defmodule AshAgentTools.ToolConverter do
  @moduledoc """
  Converts tool definitions into provider-ready formats.

  ReqLLM.Tool is used only for schema generation (to send tool definitions to the LLM).
  Actual tool execution is handled by AshAgentTools.Runtime.ToolExecutor using the
  original ToolDefinition structs, not through ReqLLM.Tool.execute.
  """

  alias AshAgentTools.DSL.Tools.ToolDefinition
  alias AshAgentTools.Tool

  def to_json_schema(tool_definitions) do
    Enum.map(tool_definitions, &Tool.to_json_schema/1)
  end

  def to_req_llm_tools(tool_definitions) do
    Enum.map(tool_definitions, &to_req_llm_tool/1)
  end

  defp to_req_llm_tool(%ReqLLM.Tool{} = tool), do: tool

  defp to_req_llm_tool(%ToolDefinition{} = tool_def) do
    {:ok, tool} =
      ReqLLM.Tool.new(
        name: to_string(tool_def.name),
        description: tool_def.description || "",
        parameter_schema: normalize_schema(tool_def.input_schema),
        callback: noop_callback()
      )

    tool
  end

  defp to_req_llm_tool(%{name: name, description: description} = tool_def) do
    {:ok, tool} =
      ReqLLM.Tool.new(
        name: to_string(name),
        description: description || "",
        parameter_schema: normalize_schema(Map.get(tool_def, :input_schema)),
        callback: noop_callback()
      )

    tool
  end

  defp normalize_schema(nil), do: []
  defp normalize_schema(%{"type" => _} = json_schema), do: json_schema
  defp normalize_schema(schema) when is_list(schema), do: schema
  defp normalize_schema(schema) when is_map(schema), do: schema

  defp noop_callback do
    fn _args -> {:ok, nil} end
  end
end
