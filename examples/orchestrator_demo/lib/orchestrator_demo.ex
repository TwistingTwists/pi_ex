defmodule OrchestratorDemo do
  @moduledoc """
  Convenience API for running the PiEx orchestrator demo from IEx.

      cd examples/orchestrator_demo
      mix deps.get
      iex -S mix

      {:ok, runner} = OrchestratorDemo.start_demo()
      OrchestratorDemo.prompt(runner, "Read sample.txt")
      {:ok, response} = OrchestratorDemo.await_done(runner)
      IO.puts(response)
  """

  alias OrchestratorDemo.AgentRunner

  @doc "Start the self-contained demo runner."
  def start_demo(opts \\ []) do
    opts
    |> Keyword.put_new(:cwd, demo_cwd())
    |> AgentRunner.start_link()
  end

  @doc "Default working directory used by the offline demo."
  def demo_cwd do
    :orchestrator_demo
    |> :code.priv_dir()
    |> List.to_string()
    |> Path.join("demo_workspace")
  end

  defdelegate prompt(runner, text), to: AgentRunner
  defdelegate await_done(runner, timeout \\ 30_000), to: AgentRunner
  defdelegate events(runner), to: AgentRunner
  defdelegate last_response(runner), to: AgentRunner
end
