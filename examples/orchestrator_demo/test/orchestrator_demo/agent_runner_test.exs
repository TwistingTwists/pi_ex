defmodule OrchestratorDemo.AgentRunnerTest do
  use ExUnit.Case, async: false

  @tag :tmp_dir
  test "orchestrates a PiEx agent and records events", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "sample.txt"), "hello from the orchestrated agent")

    {:ok, runner} = OrchestratorDemo.AgentRunner.start_link(cwd: tmp_dir)

    assert :ok = OrchestratorDemo.AgentRunner.prompt(runner, "Read sample.txt")
    assert {:ok, response} = OrchestratorDemo.AgentRunner.await_done(runner, 5_000)

    assert response =~ "hello from the orchestrated agent"

    event_types =
      runner
      |> OrchestratorDemo.AgentRunner.events()
      |> Enum.map(& &1.type)

    assert :agent_start in event_types
    assert :tool_start in event_types
    assert :tool_end in event_types
    assert :agent_end in event_types
  end
end
