defmodule PiEx.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: PiEx.TaskSupervisor},
      {DynamicSupervisor, name: :pi_ex_sessions, strategy: :one_for_one}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PiEx.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
