defmodule AshAgentTools.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Register the tool runtime with ash_agent
    AshAgent.RuntimeRegistry.register_tool_runtime(AshAgentTools.Runtime)

    # Register the tool-aware context module with ash_agent
    # This uses the registry pattern instead of mutating application config
    AshAgent.RuntimeRegistry.register_context_module(AshAgentTools.Context)

    children = [
      AshAgentTools.ToolRegistry
    ]

    opts = [strategy: :one_for_one, name: AshAgentTools.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
