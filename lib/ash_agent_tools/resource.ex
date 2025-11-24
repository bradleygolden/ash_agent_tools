defmodule AshAgentTools.Resource do
  @moduledoc """
  Ash extension that adds tool definitions to agent resources.
  """

  alias AshAgentTools.DSL.Tools

  use Spark.Dsl.Extension,
    sections: [Tools.tools()],
    transformers: [AshAgentTools.Transformers.MarkToolResource]
end
