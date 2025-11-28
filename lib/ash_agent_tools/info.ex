defmodule AshAgentTools.Info do
  @moduledoc """
  Introspection helpers for AshAgentTools extensions.
  """

  use Spark.InfoGenerator, extension: AshAgentTools.Resource, sections: [:agent_tools]

  alias AshAgentTools.DSL.Tools.ToolConfig
  alias AshAgentTools.DSL.Tools.ToolDefinition
  alias Spark.Dsl.Extension

  @spec tools(Ash.Resource.t()) :: [ToolDefinition.t()]
  def tools(resource) do
    resource
    |> Extension.get_entities([:agent_tools])
    |> Enum.filter(&match?(%ToolDefinition{}, &1))
  end

  @spec tool_configs(Ash.Resource.t()) :: [ToolConfig.t()]
  def tool_configs(resource) do
    resource
    |> Extension.get_entities([:agent_tools])
    |> Enum.filter(&match?(%ToolConfig{}, &1))
  end

  @spec tool_config(Ash.Resource.t()) :: map()
  def tool_config(resource) do
    %{
      max_iterations: Extension.get_opt(resource, [:agent_tools], :max_iterations, 5),
      timeout: Extension.get_opt(resource, [:agent_tools], :timeout, 60_000),
      on_error: Extension.get_opt(resource, [:agent_tools], :on_error, :continue)
    }
  end
end
