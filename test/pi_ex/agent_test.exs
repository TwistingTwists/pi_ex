defmodule PiEx.AgentTest do
  use ExUnit.Case, async: false

  alias PiEx.Chat.Message

  defp text_stream_fn(text) do
    fn _messages, _system_prompt, _tools, _opts ->
      msg =
        Message
        |> Ash.Changeset.for_create(:create_assistant, %{
          content: text,
          stop_reason: :end_turn
        })
        |> Ash.create!()

      {:ok, msg}
    end
  end

  defp tool_then_text_stream_fn(tool_name, tool_args, final_text) do
    call_count = :counters.new(1, [:atomics])

    fn _messages, _system_prompt, _tools, _opts ->
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)

      if count == 0 do
        msg =
          Message
          |> Ash.Changeset.for_create(:create_assistant, %{
            content: "Let me use a tool.",
            tool_calls: [%{id: "tc_1", name: tool_name, arguments: tool_args}],
            stop_reason: :tool_use
          })
          |> Ash.create!()

        {:ok, msg}
      else
        msg =
          Message
          |> Ash.Changeset.for_create(:create_assistant, %{
            content: final_text,
            stop_reason: :end_turn
          })
          |> Ash.create!()

        {:ok, msg}
      end
    end
  end

  test "basic prompt-response cycle" do
    {:ok, pid} = PiEx.Agent.start_session(stream_fn: text_stream_fn("Hello!"))
    PiEx.Agent.subscribe(pid)
    PiEx.Agent.prompt(pid, "Hi")

    assert_receive {:pi_ex_native, _session_id, %{type: :agent_start}}, 5000
    assert_receive {:pi_ex_native, _session_id, %{type: :agent_end, messages: messages}}, 5000

    assert length(messages) == 2
  end

  @tag :tmp_dir
  test "tool execution loop", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "test.txt"), "hello world")

    {:ok, pid} =
      PiEx.Agent.start_session(
        stream_fn:
          tool_then_text_stream_fn(
            "read",
            %{"path" => "test.txt"},
            "The file contains hello world."
          ),
        tools: PiEx.Tools.coding_tools(),
        cwd: tmp_dir
      )

    PiEx.Agent.subscribe(pid)
    PiEx.Agent.prompt(pid, "Read test.txt")

    assert_receive {:pi_ex_native, _sid, %{type: :agent_start}}, 5000
    assert_receive {:pi_ex_native, _sid, %{type: :agent_end, messages: msgs}}, 5000

    # user + assistant(tool_call) + tool_result + assistant(final)
    assert length(msgs) >= 4
  end

  test "steering injects between turns" do
    call_count = :counters.new(1, [:atomics])

    stream_fn = fn messages, _sp, _tools, _opts ->
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)

      has_steer = Enum.any?(messages, fn m -> m.role == :user and m.content =~ "STEER" end)
      text = if has_steer, do: "Got steering!", else: "First response"

      if count == 0 do
        msg =
          Message
          |> Ash.Changeset.for_create(:create_assistant, %{
            content: "Running...",
            tool_calls: [%{id: "tc_1", name: "bash", arguments: %{"command" => "echo hi"}}],
            stop_reason: :tool_use
          })
          |> Ash.create!()

        {:ok, msg}
      else
        msg =
          Message
          |> Ash.Changeset.for_create(:create_assistant, %{
            content: text,
            stop_reason: :end_turn
          })
          |> Ash.create!()

        {:ok, msg}
      end
    end

    {:ok, pid} = PiEx.Agent.start_session(stream_fn: stream_fn)
    PiEx.Agent.subscribe(pid)
    PiEx.Agent.prompt(pid, "Start")

    Process.sleep(50)
    PiEx.Agent.steer(pid, "STEER: change direction")

    assert_receive {:pi_ex_native, _sid, %{type: :agent_end}}, 5000
  end

  test "abort kills current operation" do
    slow_stream = fn _msgs, _sp, _tools, _opts ->
      Process.sleep(10_000)
      {:error, "should not reach"}
    end

    {:ok, pid} = PiEx.Agent.start_session(stream_fn: slow_stream)
    PiEx.Agent.subscribe(pid)
    PiEx.Agent.prompt(pid, "Start")
    Process.sleep(50)
    PiEx.Agent.abort(pid)

    assert_receive {:pi_ex_native, _sid, %{type: :agent_end}}, 5000

    state = PiEx.Agent.get_state(pid)
    assert state.status == :idle
  end

  test "get_state returns current status" do
    {:ok, pid} = PiEx.Agent.start_session(stream_fn: text_stream_fn("Hi"))
    state = PiEx.Agent.get_state(pid)
    assert state.status == :idle
    assert state.messages == []
  end
end
