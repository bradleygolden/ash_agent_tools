defmodule AshAgentTools.ResultProcessor do
  @moduledoc """
  Behavior for result processors that transform tool results.
  """

  @type tool_name :: String.t()
  @type tool_result :: {:ok, any()} | {:error, any()}
  @type result_entry :: {tool_name, tool_result}
  @type options :: keyword()

  @callback process([result_entry], options) :: [result_entry]
end

defmodule AshAgentTools.ResultProcessors do
  @moduledoc """
  Shared utilities for result processors.
  """

  def large?(data, threshold) do
    estimate_size(data) > threshold
  end

  def estimate_size(data) when is_binary(data), do: byte_size(data)
  def estimate_size(data) when is_list(data), do: length(data)
  def estimate_size(data) when is_map(data), do: map_size(data)
  def estimate_size(_data), do: 0

  def preserve_structure({name, {:ok, data}}, transform_fn) do
    {name, {:ok, transform_fn.(data)}}
  end

  def preserve_structure({_name, {:error, _reason}} = error, _transform_fn) do
    error
  end
end
