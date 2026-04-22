defmodule PiEx.InterruptTest do
  use ExUnit.Case, async: false

  alias PiEx.Chat.Message

  # Stream fn that blocks until a message is sent to a named process
  defp blocking_stream_fn(gate) do
    test_pid = self()
    fn _messages, _system_prompt, _tools, _opts ->
      send(test_pid, :stream_started)
      # Wait for gate signal via ETS
      wait_for_gate(gate)
      msg =
        Message
        |> Ash.Changeset.for_create(:create_assistant, %{content: "done", stop_reason: :end_turn})
        |> Ash.create!()
      {:ok, msg}
    end
  end

  defp blocking_tool_stream_fn(gate) do
    call_count = :counters.new(1, [:atomics])
    test_pid = self()

    fn messages, _sp, _tools, _opts ->
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)

      send(test_pid, {:stream_call, count})

      if count == 0 do
        wait_for_gate(gate)
        msg =
          Message
          |> Ash.Changeset.for_create(:create_assistant, %{
            content: "Using tool",
            tool_calls: [%{id: "tc_1", name: "bash", arguments: %{"command" => "echo hi"}}],
            stop_reason: :tool_use
          })
          |> Ash.create!()
        {:ok, msg}
      else
        has_interrupt = Enum.any?(messages, fn m -> m.role == :user and m.content =~ "INTERRUPT" end)
        msg =
          Message
          |> Ash.Changeset.for_create(:create_assistant, %{
            content: if(has_interrupt, do: "saw interrupt", else: "no interrupt"),
            stop_reason: :end_turn
          })
          |> Ash.create!()
        {:ok, msg}
      end
    end
  end

  defp new_gate do
    :atomics.new(1, signed: false)
  end

  defp open_gate(gate) do
    :atomics.put(gate, 1, 1)
  end

  defp wait_for_gate(gate) do
    if :atomics.get(gate, 1) == 1 do
      :ok
    else
      Process.sleep(5)
      wait_for_gate(gate)
    end
  end

  test "graceful while idle starts the loop" do
    {:ok, pid} = PiEx.Agent.start_session(
      stream_fn: fn _msgs, _sp, _tools, _opts ->
        msg = Message |> Ash.Changeset.for_create(:create_assistant, %{content: "Hi!", stop_reason: :end_turn}) |> Ash.create!()
        {:ok, msg}
      end
    )
    PiEx.Agent.subscribe(pid)
    PiEx.Agent.interrupt(pid, "Hello", mode: :graceful)

    assert_receive {:pi_ex, _, %{type: :interrupted, mode: :graceful, text: "Hello"}}, 5000
    assert_receive {:pi_ex, _, %{type: :agent_start}}, 5000
    assert_receive {:pi_ex, _, %{type: :agent_end, messages: msgs}}, 5000
    assert length(msgs) == 2
  end

  test "graceful while streaming queues message" do
    gate = new_gate()
    {:ok, pid} = PiEx.Agent.start_session(stream_fn: blocking_tool_stream_fn(gate))
    PiEx.Agent.subscribe(pid)
    PiEx.Agent.prompt(pid, "Start")

    assert_receive {:stream_call, 0}, 5000

    # Now streaming — interrupt gracefully
    PiEx.Agent.interrupt(pid, "INTERRUPT: change course", mode: :graceful)
    assert_receive {:pi_ex, _, %{type: :interrupted, mode: :graceful}}, 5000

    # Let the stream finish
    open_gate(gate)

    # Should see the interrupt text picked up in next turn
    assert_receive {:pi_ex, _, %{type: :agent_end}}, 5000

    state = PiEx.Agent.get_state(pid)
    assert Enum.any?(state.messages, fn m -> m.role == :user and m.content =~ "INTERRUPT" end)
  end

  test "immediate while streaming kills task and restarts" do
    gate1 = new_gate()
    gate2 = new_gate()
    call_count = :counters.new(1, [:atomics])
    test_pid = self()

    stream_fn = fn _messages, _sp, _tools, _opts ->
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)
      send(test_pid, {:stream_started, count})

      if count == 0 do
        wait_for_gate(gate1)
      else
        wait_for_gate(gate2)
      end

      msg =
        Message
        |> Ash.Changeset.for_create(:create_assistant, %{content: "done", stop_reason: :end_turn})
        |> Ash.create!()
      {:ok, msg}
    end

    {:ok, pid} = PiEx.Agent.start_session(stream_fn: stream_fn)
    PiEx.Agent.subscribe(pid)
    PiEx.Agent.prompt(pid, "Start")

    assert_receive {:stream_started, 0}, 5000

    # Interrupt immediately — should kill first task
    PiEx.Agent.interrupt(pid, "STOP NOW", mode: :immediate)

    assert_receive {:pi_ex, _, %{type: :interrupted, mode: :immediate, text: "STOP NOW"}}, 5000
    assert_receive {:stream_started, 1}, 5000

    # Let second call finish
    open_gate(gate2)
    assert_receive {:pi_ex, _, %{type: :agent_end}}, 5000

    state = PiEx.Agent.get_state(pid)
    assert Enum.any?(state.messages, fn m -> m.role == :user and m.content =~ "STOP NOW" end)
  end

  test "immediate while idle starts the loop" do
    {:ok, pid} = PiEx.Agent.start_session(
      stream_fn: fn _msgs, _sp, _tools, _opts ->
        msg = Message |> Ash.Changeset.for_create(:create_assistant, %{content: "Ok", stop_reason: :end_turn}) |> Ash.create!()
        {:ok, msg}
      end
    )
    PiEx.Agent.subscribe(pid)
    PiEx.Agent.interrupt(pid, "Go", mode: :immediate)

    assert_receive {:pi_ex, _, %{type: :interrupted, mode: :immediate}}, 5000
    assert_receive {:pi_ex, _, %{type: :agent_end}}, 5000
  end

  test "after_turn while streaming skips tools and injects message" do
    gate = new_gate()
    {:ok, pid} = PiEx.Agent.start_session(stream_fn: blocking_tool_stream_fn(gate))
    PiEx.Agent.subscribe(pid)
    PiEx.Agent.prompt(pid, "Start")

    assert_receive {:stream_call, 0}, 5000

    # Queue after_turn interrupt
    PiEx.Agent.interrupt(pid, "INTERRUPT: redirect", mode: :after_turn)

    # Let the LLM finish (it will return tool_calls)
    open_gate(gate)

    # Should see interrupted event
    assert_receive {:pi_ex, _, %{type: :interrupted, mode: :after_turn, text: "INTERRUPT: redirect"}}, 5000

    # The agent should re-enter loop (second stream call) without executing tools
    assert_receive {:stream_call, 1}, 5000

    # Agent ends
    assert_receive {:pi_ex, _, %{type: :agent_end}}, 5000

    state = PiEx.Agent.get_state(pid)
    # Should NOT have tool role messages (tools were skipped)
    refute Enum.any?(state.messages, fn m -> m.role == :tool end)
    # Should have the interrupt message
    assert Enum.any?(state.messages, fn m -> m.role == :user and m.content =~ "INTERRUPT: redirect" end)
  end
end
