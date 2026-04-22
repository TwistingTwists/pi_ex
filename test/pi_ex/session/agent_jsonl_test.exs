defmodule PiEx.Session.AgentJSONLTest do
  use ExUnit.Case, async: false

  @tag :tmp_dir
  test "agent session can be saved to JSONL after prompt cycle", %{tmp_dir: tmp_dir} do
    call_count = :counters.new(1, [:atomics])

    stream_fn = fn _msgs, _sp, _tools, _opts ->
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)

      if count == 0 do
        tc = %PiEx.Chat.ToolCall{id: "tc1", name: "bash", arguments: %{"command" => "echo hello"}}

        msg =
          Ash.Changeset.for_create(PiEx.Chat.Message, :create_assistant, %{
            content: "Let me run that.",
            tool_calls: [tc],
            stop_reason: :tool_use
          })
          |> Ash.create!()

        {:ok, msg}
      else
        msg =
          Ash.Changeset.for_create(PiEx.Chat.Message, :create_assistant, %{
            content: "Done! Output was hello.",
            stop_reason: :end_turn
          })
          |> Ash.create!()

        {:ok, msg}
      end
    end

    {:ok, pid} = PiEx.Agent.start_session(stream_fn: stream_fn, cwd: tmp_dir)
    PiEx.Agent.subscribe(pid)
    PiEx.Agent.prompt(pid, "run echo hello")

    assert_receive {:pi_ex, _session_id, %{type: :agent_end}}, 5000

    state = PiEx.Agent.get_state(pid)
    assert length(state.messages) >= 3

    session = PiEx.Agent.get_session(pid)

    jsonl_path = Path.join(tmp_dir, "session.jsonl")
    :ok = PiEx.Session.JSONL.save(session, jsonl_path)

    assert File.exists?(jsonl_path)
    lines = jsonl_path |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) >= 5

    loaded = PiEx.Session.JSONL.load(jsonl_path)
    assert length(loaded.messages) == length(state.messages)
    assert hd(loaded.messages).content == "run echo hello"
  end
end
