defmodule AshAgentTools.Template.Dsl do
  @moduledoc false

  alias AshAgentTools.DSL.Tools

  use Spark.Dsl.Extension,
    sections: [Tools.template_agent_tools()],
    transformers: []
end
