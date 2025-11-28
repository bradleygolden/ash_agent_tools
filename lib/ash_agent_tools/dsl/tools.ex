defmodule AshAgentTools.DSL.Tools do
  @moduledoc """
  DSL for defining tools available to agents.
  """

  defmodule ToolDefinition do
    @moduledoc false
    @type t :: %__MODULE__{
            name: atom(),
            description: String.t() | nil,
            action: {module(), atom()} | atom() | nil,
            function: {module(), atom(), list()} | (map(), map() -> any()) | nil,
            input_schema: any(),
            output_schema: any(),
            config: keyword(),
            __spark_metadata__: map() | nil
          }
    defstruct [
      :name,
      :description,
      :action,
      :function,
      :input_schema,
      :output_schema,
      :config,
      :__spark_metadata__
    ]
  end

  defmodule ToolConfig do
    @moduledoc false
    @type t :: %__MODULE__{
            module: module(),
            config: keyword(),
            __spark_metadata__: map() | nil
          }
    defstruct [:module, :config, :__spark_metadata__]
  end

  @tool %Spark.Dsl.Entity{
    name: :tool,
    describe: """
    Defines a tool that the agent can use.

    Can be either an inline tool definition or a reference to a tool template module.
    """,
    examples: [
      """
      # Inline tool definition
      tool :get_customer do
        description "Retrieve customer information by ID"
        action {MyApp.Customers.Customer, :read}
        input_schema Zoi.object(%{
          customer_id: Zoi.string()
        }, coerce: true)
      end
      """,
      """
      # Tool template reference
      tool MyMarketplace.Tools.WebSearch, config: [api_key: {:env, "API_KEY"}]
      """
    ],
    target: AshAgentTools.DSL.Tools.ToolDefinition,
    args: [:name],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the tool (atom) or a tool template module"
      ],
      description: [
        type: :string,
        required: false,
        doc: "Human-readable description of what the tool does (required for inline tools)"
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
      input_schema: [
        type: :any,
        required: false,
        doc:
          "Zoi schema for input parameter validation. Use Zoi.object/2 with coerce: true for LLM inputs."
      ],
      output_schema: [
        type: :any,
        required: false,
        doc:
          "Zoi schema for output validation and documentation. Logs warnings on mismatch but does not fail."
      ],
      config: [
        type: :keyword_list,
        default: [],
        doc:
          "Configuration for tool templates. Supports {:env, \"VAR\"} and {:config, :app, :key}"
      ]
    ],
    transform: {__MODULE__, :transform_tool, []}
  }

  @agent_tools %Spark.Dsl.Section{
    name: :agent_tools,
    describe: """
    Defines tools available to the agent for function calling.

    Tools allow agents to interact with external systems during multi-turn
    conversations. Each tool must specify either an Ash action or an Elixir function.
    """,
    examples: [
      """
      agent_tools do
        max_iterations 5
        timeout 60_000
        on_error :continue

        tool :get_customer do
          description "Retrieve customer information by ID"
          action {MyApp.Customers.Customer, :read}
          input_schema Zoi.object(%{
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

  @doc false
  def transform_tool(%{name: name} = entity) do
    if tool_template?(name) do
      transform_template_reference(entity)
    else
      validate_inline_tool(entity)
    end
  end

  defp transform_template_reference(%ToolDefinition{name: module, config: config} = entity) do
    {:ok,
     %ToolConfig{
       module: module,
       config: config || [],
       __spark_metadata__: entity.__spark_metadata__
     }}
  end

  defp validate_inline_tool(%{action: nil, function: nil}) do
    {:error, "Inline tool must specify either :action or :function"}
  end

  defp validate_inline_tool(%{action: action, function: function})
       when not is_nil(action) and not is_nil(function) do
    {:error, "Tool cannot specify both :action and :function, choose one"}
  end

  defp validate_inline_tool(%{description: nil}) do
    {:error, "Inline tool must specify a :description"}
  end

  defp validate_inline_tool(tool), do: {:ok, tool}

  defp tool_template?(name) when is_atom(name) do
    # Check if the name looks like a module (uppercase first character)
    # Tool names like :search are lowercase atoms
    # Module names like MyApp.Tools.WebSearch start with uppercase
    name_string = Atom.to_string(name)

    cond do
      # Elixir modules always start with "Elixir." internally
      String.starts_with?(name_string, "Elixir.") ->
        true

      # Check if first char is uppercase (module alias like WebSearch)
      String.match?(name_string, ~r/^[A-Z]/) ->
        true

      # Otherwise it's a regular tool name like :search
      true ->
        false
    end
  end

  defp tool_template?(_), do: false

  def agent_tools, do: @agent_tools

  def template_agent_tools do
    %{@agent_tools | schema: template_schema(), entities: [@tool]}
  end

  defp template_schema do
    @agent_tools.schema
    |> Keyword.delete(:max_iterations)
    |> Keyword.delete(:timeout)
    |> Keyword.delete(:on_error)
  end
end
