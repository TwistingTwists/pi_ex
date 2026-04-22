defmodule PiEx.HooksTest do
  use ExUnit.Case, async: true

  describe "before_tool_call blocking" do
    test "blocks tool execution with reason" do
      tool_call = %{id: "tc1", name: "fake", arguments: %{"input" => "test"}}

      hooks = %{
        before_tool_call: fn _tc, _args, _ctx ->
          {:block, "Not allowed"}
        end
      }

      defmodule BlockTestTool do
        @behaviour PiEx.Tool
        def name, do: "fake"
        def description, do: "fake"
        def parameters, do: %{}
        def execute(_, _), do: {:ok, [%{type: :text, text: "should not run"}]}
      end

      tool_map = %{"fake" => BlockTestTool}
      [result] = PiEx.Turn.execute_tools([tool_call], tool_map, %{cwd: "/tmp"}, hooks)

      assert result.is_error == true
      assert result.content =~ "Not allowed"
    end

    test "allows execution when returning :ok" do
      tool_call = %{id: "tc1", name: "fake", arguments: %{"input" => "test"}}

      hooks = %{
        before_tool_call: fn _tc, _args, _ctx -> :ok end
      }

      defmodule AllowTestTool do
        @behaviour PiEx.Tool
        def name, do: "fake"
        def description, do: "fake"
        def parameters, do: %{}
        def execute(%{"input" => input}, _), do: {:ok, [%{type: :text, text: "got: #{input}"}]}
      end

      tool_map = %{"fake" => AllowTestTool}
      [result] = PiEx.Turn.execute_tools([tool_call], tool_map, %{cwd: "/tmp"}, hooks)

      assert result.is_error == false
      assert result.content =~ "got: test"
    end
  end

  describe "after_tool_call mutation" do
    test "overrides tool result" do
      tool_call = %{id: "tc1", name: "fake", arguments: %{}}

      hooks = %{
        after_tool_call: fn _tc, _args, _result, _is_error, _ctx ->
          {:override, %{content: "modified result", is_error: false}}
        end
      }

      defmodule OverrideTestTool do
        @behaviour PiEx.Tool
        def name, do: "fake"
        def description, do: "fake"
        def parameters, do: %{}
        def execute(_, _), do: {:ok, [%{type: :text, text: "original"}]}
      end

      tool_map = %{"fake" => OverrideTestTool}
      [result] = PiEx.Turn.execute_tools([tool_call], tool_map, %{cwd: "/tmp"}, hooks)

      assert result.content == "modified result"
    end

    test "can convert success to error" do
      tool_call = %{id: "tc1", name: "fake", arguments: %{}}

      hooks = %{
        after_tool_call: fn _tc, _args, _result, _is_error, _ctx ->
          {:override, %{content: "blocked after the fact", is_error: true}}
        end
      }

      defmodule ErrorOverrideTestTool do
        @behaviour PiEx.Tool
        def name, do: "fake"
        def description, do: "fake"
        def parameters, do: %{}
        def execute(_, _), do: {:ok, [%{type: :text, text: "original"}]}
      end

      tool_map = %{"fake" => ErrorOverrideTestTool}
      [result] = PiEx.Turn.execute_tools([tool_call], tool_map, %{cwd: "/tmp"}, hooks)

      assert result.is_error == true
      assert result.content == "blocked after the fact"
    end

    test "passes through when returning :ok" do
      tool_call = %{id: "tc1", name: "fake", arguments: %{}}

      hooks = %{
        after_tool_call: fn _tc, _args, _result, _is_error, _ctx -> :ok end
      }

      defmodule PassthroughTestTool do
        @behaviour PiEx.Tool
        def name, do: "fake"
        def description, do: "fake"
        def parameters, do: %{}
        def execute(_, _), do: {:ok, [%{type: :text, text: "original"}]}
      end

      tool_map = %{"fake" => PassthroughTestTool}
      [result] = PiEx.Turn.execute_tools([tool_call], tool_map, %{cwd: "/tmp"}, hooks)

      assert result.content =~ "original"
    end
  end

  describe "no hooks (backwards compatibility)" do
    test "works without hooks argument" do
      tool_call = %{id: "tc1", name: "fake", arguments: %{}}

      defmodule NoHookTestTool do
        @behaviour PiEx.Tool
        def name, do: "fake"
        def description, do: "fake"
        def parameters, do: %{}
        def execute(_, _), do: {:ok, [%{type: :text, text: "works"}]}
      end

      tool_map = %{"fake" => NoHookTestTool}
      [result] = PiEx.Turn.execute_tools([tool_call], tool_map, %{cwd: "/tmp"})

      assert result.content =~ "works"
    end
  end

  describe "Agent with hooks" do
    test "hooks are called during agent prompt cycle" do
      test_pid = self()

      hooks = %{
        before_tool_call: fn tc, _args, _ctx ->
          send(test_pid, {:before, tc.name})
          :ok
        end,
        after_tool_call: fn tc, _args, _result, _is_error, _ctx ->
          send(test_pid, {:after, tc.name})
          :ok
        end
      }

      call_count = :counters.new(1, [:atomics])

      stream_fn = fn _msgs, _sp, _tools, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          tc = %PiEx.Chat.ToolCall{id: "tc1", name: "bash", arguments: %{"command" => "echo hi"}}

          msg =
            Ash.Changeset.for_create(PiEx.Chat.Message, :create_assistant, %{
              content: "Running...",
              tool_calls: [tc],
              stop_reason: :tool_use
            })
            |> Ash.create!()

          {:ok, msg}
        else
          msg =
            Ash.Changeset.for_create(PiEx.Chat.Message, :create_assistant, %{
              content: "Done.",
              stop_reason: :end_turn
            })
            |> Ash.create!()

          {:ok, msg}
        end
      end

      {:ok, pid} = PiEx.Agent.start_session(stream_fn: stream_fn, hooks: hooks)
      PiEx.Agent.subscribe(pid)
      PiEx.Agent.prompt(pid, "test")

      assert_receive {:before, "bash"}, 5000
      assert_receive {:after, "bash"}, 5000
      assert_receive {:pi_ex, _, %{type: :agent_end}}, 5000
    end

    test "before_tool_call can block in agent" do
      hooks = %{
        before_tool_call: fn _tc, _args, _ctx -> {:block, "Dangerous!"} end
      }

      call_count = :counters.new(1, [:atomics])

      stream_fn = fn _msgs, _sp, _tools, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          tc = %PiEx.Chat.ToolCall{id: "tc1", name: "bash", arguments: %{"command" => "rm -rf /"}}

          msg =
            Ash.Changeset.for_create(PiEx.Chat.Message, :create_assistant, %{
              content: "Deleting...",
              tool_calls: [tc],
              stop_reason: :tool_use
            })
            |> Ash.create!()

          {:ok, msg}
        else
          msg =
            Ash.Changeset.for_create(PiEx.Chat.Message, :create_assistant, %{
              content: "Blocked.",
              stop_reason: :end_turn
            })
            |> Ash.create!()

          {:ok, msg}
        end
      end

      {:ok, pid} = PiEx.Agent.start_session(stream_fn: stream_fn, hooks: hooks)
      PiEx.Agent.subscribe(pid)
      PiEx.Agent.prompt(pid, "delete everything")

      assert_receive {:pi_ex, _, %{type: :tool_end, message: msg}}, 5000
      assert msg.is_error == true
      assert msg.content =~ "Dangerous!"
      assert_receive {:pi_ex, _, %{type: :agent_end}}, 5000
    end
  end
end
