defmodule AshAgentTools.ToolRegistry do
  @moduledoc """
  Registry for tools that can be shared across agents in a domain.
  """

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def register_tool(domain, tool_name, tool_impl) do
    Agent.update(__MODULE__, fn registry ->
      domain_tools = Map.get(registry, domain, %{})
      updated_domain_tools = Map.put(domain_tools, tool_name, tool_impl)
      Map.put(registry, domain, updated_domain_tools)
    end)
  end

  def get_tool(domain, tool_name) do
    Agent.get(__MODULE__, fn registry ->
      get_in(registry, [domain, tool_name])
    end)
  end

  def list_tools(domain) do
    Agent.get(__MODULE__, fn registry ->
      Map.get(registry, domain, %{})
    end)
  end

  def unregister_tool(domain, tool_name) do
    Agent.update(__MODULE__, fn registry ->
      domain_tools = Map.get(registry, domain, %{})
      updated_domain_tools = Map.delete(domain_tools, tool_name)

      if map_size(updated_domain_tools) == 0 do
        Map.delete(registry, domain)
      else
        Map.put(registry, domain, updated_domain_tools)
      end
    end)
  end

  def clear_domain(domain) do
    Agent.update(__MODULE__, fn registry ->
      Map.delete(registry, domain)
    end)
  end

  def clear_all do
    Agent.update(__MODULE__, fn _registry -> %{} end)
  end
end
