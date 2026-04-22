defmodule PiEx do
  @moduledoc "PiEx - An Elixir agentic library."

  @doc "Start a new agent session."
  defdelegate start_session(opts \\ []), to: PiEx.Agent

  @doc "Send a prompt to the agent."
  defdelegate prompt(pid, text), to: PiEx.Agent

  @doc "Steer the agent mid-run."
  defdelegate steer(pid, text), to: PiEx.Agent

  @doc "Abort the current operation."
  defdelegate abort(pid), to: PiEx.Agent

  @doc "Subscribe to session events."
  defdelegate subscribe(pid), to: PiEx.Agent

  @doc "Get the current session state."
  defdelegate get_state(pid), to: PiEx.Agent

  @doc """
  Hello world.

  ## Examples

      iex> PiEx.hello()
      :world

  """
  def hello do
    :world
  end
end
