defmodule AshAgentTools.DSL.Tools do
  @moduledoc """
  DSL for defining tools available to agents.
  """

  defmodule ToolDefinition do
    @moduledoc false
    defstruct [:name, :description, :action, :function, :schema, :__spark_metadata__]
  end

  @tool %Spark.Dsl.Entity{
    name: :tool,
    describe: "Defines a tool that the agent can use",
    examples: [
      """
      tool :get_customer do
        description "Retrieve customer information by ID"
        action {MyApp.Customers.Customer, :read}
        schema Zoi.object(%{
          customer_id: Zoi.string()
        }, coerce: true)
      end
      """,
      """
      tool :send_email do
        description "Send an email to a customer"
        function {MyApp.Email, :send, []}
        schema Zoi.object(%{
          to: Zoi.string(),
          subject: Zoi.string(),
          body: Zoi.string()
        }, coerce: true)
      end
      """
    ],
    target: AshAgentTools.DSL.Tools.ToolDefinition,
    args: [:name],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the tool"
      ],
      description: [
        type: :string,
        required: true,
        doc: "Human-readable description of what the tool does"
      ],
      action: [
        type: {:or, [{:tuple, [:atom, :atom]}, :atom]},
        required: false,
        doc: "Ash action to execute. Format: {Resource, :action_name} or ResourceModule"
      ],
      function: [
        type: {:or, [{:tuple, [:atom, :atom, :any]}, {:fun, 2}]},
        required: false,
        doc: "Elixir function to execute. Format: {Module, :function, args} or anonymous function"
      ],
      schema: [
        type: :any,
        required: false,
        doc:
          "Zoi schema for parameter validation. Use Zoi.object/2 with coerce: true for LLM inputs."
      ]
    ],
    transform: {__MODULE__, :validate_tool, []}
  }

  @tools %Spark.Dsl.Section{
    name: :tools,
    describe: """
    Defines tools available to the agent for function calling.

    Tools allow agents to interact with external systems during multi-turn
    conversations. Each tool must specify either an Ash action or an Elixir function.
    """,
    examples: [
      """
      tools do
        max_iterations 5
        timeout 60_000
        on_error :continue

        tool :get_customer do
          description "Retrieve customer information by ID"
          action {MyApp.Customers.Customer, :read}
          schema Zoi.object(%{
            customer_id: Zoi.string()
          }, coerce: true)
        end
      end
      """
    ],
    schema: [
      max_iterations: [
        type: :pos_integer,
        default: 10,
        doc: "Maximum number of tool execution iterations in a single conversation"
      ],
      timeout: [
        type: :pos_integer,
        default: 30_000,
        doc: "Timeout in milliseconds for individual tool execution"
      ],
      on_error: [
        type: {:in, [:continue, :halt]},
        default: :continue,
        doc:
          "How to handle tool execution errors. :continue injects error into conversation, :halt stops execution"
      ]
    ],
    entities: [@tool]
  }

  def validate_tool(%{action: nil, function: nil}) do
    {:error, "Tool must specify either :action or :function"}
  end

  def validate_tool(%{action: action, function: function})
      when not is_nil(action) and not is_nil(function) do
    {:error, "Tool cannot specify both :action and :function, choose one"}
  end

  def validate_tool(tool), do: {:ok, tool}

  def tools, do: @tools
end
