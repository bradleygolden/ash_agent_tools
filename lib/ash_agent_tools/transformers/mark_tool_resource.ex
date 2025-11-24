defmodule AshAgentTools.Transformers.MarkToolResource do
  @moduledoc false

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state) do
    {:ok, Transformer.persist(dsl_state, :requires_tool_runtime?, true)}
  end
end
