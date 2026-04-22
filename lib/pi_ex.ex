defmodule PiEx do
  @moduledoc "PiEx - An Elixir agentic library."

  defdelegate start_session(opts \\ []), to: PiEx.Agent
  defdelegate prompt(pid, text), to: PiEx.Agent
  defdelegate steer(pid, text), to: PiEx.Agent
  defdelegate abort(pid), to: PiEx.Agent
  defdelegate subscribe(pid), to: PiEx.Agent
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
