defmodule AshAgentTools.Template do
  @moduledoc """
  DSL for defining composable tool templates as Spark fragments.

  Templates are fragments of `Ash.Resource` that provide tool configuration.
  Use them by adding to your resource's `fragments:` list.

  ## Defining a Tool Template

      defmodule MyMarketplace.Tools.WebSearch do
        use AshAgentTools.Template

        agent_tools do
          tool :web_search do
            description "Search the web"
            schema Zoi.object(%{query: Zoi.string()}, coerce: true)
            function {__MODULE__, :execute, []}
          end
        end

        def execute(%{query: query}, context) do
          {:ok, %{results: []}}
        end
      end

  ## Using a Tool Template

      defmodule MyApp.Agent do
        use Ash.Resource,
          extensions: [AshAgent.Resource, AshAgentTools.Resource],
          fragments: [MyMarketplace.Tools.WebSearch]

        agent_tools do
          tool MyMarketplace.Tools.WebSearch,
            config: [api_key: {:env, "API_KEY"}]
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      use Spark.Dsl.Fragment,
        of: Ash.Resource,
        extensions: [AshAgentTools.Template.Dsl]

      Module.register_attribute(__MODULE__, :config_schema, persist: true)
    end
  end
end
