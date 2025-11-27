defmodule AshAgentTools.Info do
  @moduledoc """
  Introspection helpers for AshAgentTools extensions.
  """

  use Spark.InfoGenerator, extension: AshAgentTools.Resource, sections: [:agent_tools]

  alias Spark.Dsl.Extension

  @spec tools(Ash.Resource.t()) :: [map()]
  def tools(resource) do
    Extension.get_entities(resource, [:agent_tools])
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
