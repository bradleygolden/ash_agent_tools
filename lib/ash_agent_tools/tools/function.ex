defmodule AshAgentTools.Tools.Function do
  @moduledoc """
  Tool implementation for executing Elixir functions.
  """

  @behaviour AshAgentTools.Tool

  defstruct [:name, :description, :function]

  def new(opts) do
    %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      description: Keyword.fetch!(opts, :description),
      function: Keyword.fetch!(opts, :function)
    }
  end

  def to_schema(%__MODULE__{} = tool) do
    %{
      "name" => to_string(tool.name),
      "description" => tool.description || "",
      "parameters" => %{
        "type" => "object",
        "properties" => %{},
        "required" => []
      }
    }
  end

  @impl true
  def name, do: :function

  @impl true
  def description, do: "Executes an Elixir function"

  @impl true
  def schema do
    %{
      name: "function",
      description: "Executes an Elixir function",
      parameters: %{
        type: :object,
        properties: %{},
        required: []
      }
    }
  end

  @impl true
  def execute(args, context) do
    tool = context.tool
    call_function(tool.function, args, context)
  end

  defp call_function({module, function, extra_args}, args, context) when is_list(extra_args) do
    result = apply(module, function, [args | extra_args] ++ [context])
    normalize_result(result)
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp call_function({module, function, extra_args}, args, _context) do
    result = apply(module, function, [args | extra_args])
    normalize_result(result)
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp call_function(fun, args, context) when is_function(fun, 2) do
    result = fun.(args, context)
    normalize_result(result)
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp call_function(fun, args, _context) when is_function(fun, 1) do
    result = fun.(args)
    normalize_result(result)
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp call_function(invalid, _args, _context) do
    {:error, "Invalid function type: #{inspect(invalid)}"}
  end

  defp normalize_result({:halt, result}), do: {:halt, result}
  defp normalize_result({:ok, result}) when is_map(result), do: {:ok, result}
  defp normalize_result({:ok, result}), do: {:ok, %{result: result}}
  defp normalize_result({:error, _} = error), do: error
  defp normalize_result(result) when is_map(result), do: {:ok, result}
  defp normalize_result(result), do: {:ok, %{result: result}}
end
