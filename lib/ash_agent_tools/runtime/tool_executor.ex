defmodule AshAgentTools.Runtime.ToolExecutor do
  @moduledoc """
  Executes tools requested by LLM agents.
  """

  alias AshAgentTools.Tools.{AshAction, Function}

  def execute_tools(tool_calls, tool_definitions, runtime_context) do
    Enum.map(tool_calls, fn tool_call ->
      execute_tool(tool_call, tool_definitions, runtime_context)
    end)
  end

  defp execute_tool(%{id: id, name: name, arguments: args}, tool_definitions, runtime_context) do
    with {:ok, tool_def} <- find_tool_or_error(name, tool_definitions),
         context = build_context(runtime_context, tool_def),
         {:ok, validated_args} <- validate_args(args, tool_def),
         result <- execute_tool_impl(tool_def, validated_args, context),
         result <- validate_output(result, tool_def) do
      wrap_result(id, result)
    else
      {:error, :not_found} -> {id, {:error, "Tool #{inspect(name)} not found"}}
      {:error, errors} -> {id, {:error, format_validation_errors(errors)}}
    end
  end

  defp find_tool_or_error(name, tool_definitions) do
    case find_tool(name, tool_definitions) do
      nil -> {:error, :not_found}
      tool_def -> {:ok, tool_def}
    end
  end

  defp wrap_result(id, {:ok, result}), do: {id, {:ok, result}}
  defp wrap_result(id, {:halt, result}), do: {id, {:halt, result}}
  defp wrap_result(id, {:error, _} = error), do: {id, error}

  defp validate_args(args, %{input_schema: schema}) when not is_nil(schema) do
    if json_schema?(schema) do
      {:ok, args}
    else
      Zoi.parse(schema, args)
    end
  end

  defp validate_args(args, _tool_def) do
    {:ok, args}
  end

  defp json_schema?(%{"type" => _}), do: true
  defp json_schema?(%{"properties" => _}), do: true
  defp json_schema?(_), do: false

  defp validate_output({:ok, result}, %{output_schema: schema, name: name})
       when not is_nil(schema) do
    case Zoi.parse(schema, result) do
      {:ok, validated} ->
        {:ok, validated}

      {:error, errors} ->
        require Logger

        Logger.warning("Tool #{name} output validation failed: #{Zoi.prettify_errors(errors)}")

        {:ok, result}
    end
  end

  defp validate_output(result, _tool_def), do: result

  defp format_validation_errors(errors) do
    "Parameter validation failed: " <> Zoi.prettify_errors(errors)
  end

  defp find_tool(name, tool_definitions) when is_atom(name) do
    Enum.find(tool_definitions, fn tool ->
      tool_name = get_tool_name(tool)
      tool_name == name or to_string(tool_name) == to_string(name)
    end)
  end

  defp get_tool_name(%{name: name}), do: name
  defp get_tool_name(tool), do: Map.get(tool, :name)

  defp execute_tool_impl(%{action: {resource, action_name}} = tool_def, args, context) do
    tool = build_ash_action_tool(tool_def, resource, action_name)
    AshAction.execute(args, Map.put(context, :tool, tool))
  end

  defp execute_tool_impl(%{function: function} = tool_def, args, context) do
    tool = build_function_tool(tool_def, function)
    Function.execute(args, Map.put(context, :tool, tool))
  end

  defp execute_tool_impl(_tool_def, _args, _context) do
    {:error, "Tool must specify either :action or :function"}
  end

  defp build_ash_action_tool(tool_def, resource, action_name) do
    AshAction.new(
      name: tool_def.name,
      description: tool_def.description,
      resource: resource,
      action_name: action_name
    )
  end

  defp build_function_tool(tool_def, function) do
    Function.new(
      name: tool_def.name,
      description: tool_def.description,
      function: function
    )
  end

  defp build_context(runtime_context, _tool_def) do
    agent = runtime_context[:agent]

    tool_configs =
      if agent do
        resolve_tool_configs(agent)
      else
        %{}
      end

    Map.put(runtime_context, :tool_configs, tool_configs)
  end

  defp resolve_tool_configs(agent) do
    agent
    |> AshAgentTools.Info.tool_configs()
    |> Enum.map(fn %{module: module, config: config} ->
      resolved = resolve_config_values(config)
      {module, Map.new(resolved)}
    end)
    |> Map.new()
  end

  defp resolve_config_values(config) do
    Enum.map(config, fn {k, v} -> {k, resolve_value(v)} end)
  end

  defp resolve_value({:env, var}), do: System.get_env(var)
  defp resolve_value({:config, app, key}), do: Application.get_env(app, key)
  defp resolve_value(value), do: value
end
