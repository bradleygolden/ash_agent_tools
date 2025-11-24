defmodule AshAgentTools.ResultProcessors.Truncate do
  @moduledoc """
  Truncates tool results that exceed a specified size threshold.
  """

  @behaviour AshAgentTools.ResultProcessor

  alias AshAgentTools.ResultProcessors

  @default_max_size 1_000
  @default_marker "... [truncated]"

  @impl true
  def process(results, opts \\ []) when is_list(results) do
    max_size = Keyword.get(opts, :max_size, @default_max_size)
    marker = Keyword.get(opts, :marker, @default_marker)

    unless is_integer(max_size) and max_size > 0 do
      raise ArgumentError, "max_size must be a positive integer, got: #{inspect(max_size)}"
    end

    Enum.map(results, fn result_entry ->
      truncate_result(result_entry, max_size, marker)
    end)
  end

  defp truncate_result({name, {:ok, data}} = entry, max_size, marker) do
    if ResultProcessors.large?(data, max_size) do
      truncated_data = truncate_data(data, max_size, marker)
      {name, {:ok, truncated_data}}
    else
      entry
    end
  end

  defp truncate_result({_name, {:error, _reason}} = entry, _max_size, _marker) do
    entry
  end

  defp truncate_data(data, max_size, marker) when is_binary(data) do
    if String.length(data) > max_size do
      String.slice(data, 0, max_size) <> marker
    else
      data
    end
  end

  defp truncate_data(data, max_size, marker) when is_list(data) do
    if length(data) > max_size do
      Enum.take(data, max_size) ++ [marker]
    else
      data
    end
  end

  defp truncate_data(data, max_size, marker) when is_map(data) do
    keys = Map.keys(data)
    key_count = length(keys)

    if key_count > max_size do
      kept_keys = Enum.take(keys, max_size)
      truncated_map = Map.take(data, kept_keys)

      Map.put(truncated_map, :__truncated__, marker)
    else
      data
    end
  end

  defp truncate_data(data, _max_size, _marker) do
    data
  end
end
