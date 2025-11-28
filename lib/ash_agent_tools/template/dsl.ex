defmodule AshAgentTools.Template.Dsl do
  @moduledoc false

  use Spark.Dsl.Extension,
    sections: [AshAgentTools.DSL.Tools.template_agent_tools()],
    transformers: []
end
