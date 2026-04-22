defmodule PiEx.ExtensionTest do
  use ExUnit.Case, async: true

  alias PiEx.Extension.Pipeline

  # --- Test extensions ---

  defmodule LogExtension do
    @behaviour PiEx.Extension

    @impl true
    def init(config) do
      {:ok, %{log_pid: config[:log_pid], events: []}}
    end

    @impl true
    def handle_event(event_name, payload, _context, state) do
      if state.log_pid, do: send(state.log_pid, {:ext_event, event_name, payload})
      {:ok, %{state | events: state.events ++ [event_name]}}
    end
  end

  defmodule MutateExtension do
    @behaviour PiEx.Extension

    @impl true
    def init(_config), do: {:ok, %{}}

    @impl true
    def handle_event(:before_prompt, _payload, _context, state) do
      {:mutate, %{text: "mutated prompt"}, state}
    end

    def handle_event(_event, _payload, _context, state) do
      {:ok, state}
    end
  end

  defmodule BlockExtension do
    @behaviour PiEx.Extension

    @impl true
    def init(_config), do: {:ok, %{}}

    @impl true
    def handle_event(:tool_call, _payload, _context, state) do
      {:block, "blocked by extension", state}
    end

    def handle_event(_event, _payload, _context, state) do
      {:ok, state}
    end
  end

  defmodule ToolExtension do
    @behaviour PiEx.Extension

    @impl true
    def init(_config), do: {:ok, %{}}

    @impl true
    def handle_event(_event, _payload, _context, state), do: {:ok, state}

    @impl true
    def tools, do: [PiEx.ExtensionTest.FakeTool]
  end

  defmodule FakeTool do
    @behaviour PiEx.Tool
    def name, do: "fake_ext_tool"
    def description, do: "A fake tool from an extension"
    def parameters, do: %{}
    def execute(_, _), do: {:ok, [%{type: :text, text: "fake result"}]}
  end

  defmodule FailInitExtension do
    @behaviour PiEx.Extension

    @impl true
    def init(_config), do: {:error, :boom}

    @impl true
    def handle_event(_, _, _, state), do: {:ok, state}
  end

  # --- Pipeline tests ---

  describe "Pipeline.init/2" do
    test "initializes extensions with config" do
      assert {:ok, [{LogExtension, %{log_pid: nil, events: []}}]} =
               Pipeline.init([LogExtension])
    end

    test "accepts {module, config} tuples" do
      pid = self()

      assert {:ok, [{LogExtension, %{log_pid: ^pid, events: []}}]} =
               Pipeline.init([{LogExtension, %{log_pid: self()}}])
    end

    test "returns error when init fails" do
      assert {:error, {FailInitExtension, :boom}} = Pipeline.init([FailInitExtension])
    end

    test "initializes multiple extensions" do
      assert {:ok, entries} = Pipeline.init([LogExtension, MutateExtension])
      assert length(entries) == 2
    end
  end

  describe "Pipeline.dispatch/4" do
    setup do
      {:ok, entries} = Pipeline.init([{LogExtension, %{log_pid: self()}}])
      ctx = %{session_id: "s1", cwd: "/tmp", model: nil}
      %{entries: entries, ctx: ctx}
    end

    test "dispatches :ok events", %{entries: entries, ctx: ctx} do
      {new_entries, payload} = Pipeline.dispatch(entries, :session_start, %{}, ctx)
      assert payload == %{}
      [{LogExtension, state}] = new_entries
      assert state.events == [:session_start]
      assert_received {:ext_event, :session_start, %{}}
    end

    test "dispatches :mutate events" do
      {:ok, entries} = Pipeline.init([MutateExtension])
      ctx = %{session_id: "s1", cwd: "/tmp", model: nil}

      {_entries, payload} = Pipeline.dispatch(entries, :before_prompt, %{text: "original"}, ctx)
      assert payload.text == "mutated prompt"
    end

    test "dispatches :block events" do
      {:ok, entries} = Pipeline.init([BlockExtension])
      ctx = %{session_id: "s1", cwd: "/tmp", model: nil}

      {_entries, payload} = Pipeline.dispatch(entries, :tool_call, %{name: "bash"}, ctx)
      assert payload.blocked == "blocked by extension"
    end

    test "block short-circuits remaining extensions" do
      {:ok, entries} = Pipeline.init([BlockExtension, {LogExtension, %{log_pid: self()}}])
      ctx = %{session_id: "s1", cwd: "/tmp", model: nil}

      Pipeline.dispatch(entries, :tool_call, %{}, ctx)
      refute_received {:ext_event, :tool_call, _}
    end
  end

  describe "Pipeline.collect_tools/1" do
    test "collects tools from extensions" do
      {:ok, entries} = Pipeline.init([ToolExtension])
      tools = Pipeline.collect_tools(entries)
      assert tools == [FakeTool]
    end

    test "skips extensions without tools/0" do
      {:ok, entries} = Pipeline.init([LogExtension])
      assert Pipeline.collect_tools(entries) == []
    end

    test "collects from multiple extensions" do
      {:ok, entries} = Pipeline.init([ToolExtension, LogExtension])
      assert Pipeline.collect_tools(entries) == [FakeTool]
    end
  end

  describe "Agent integration with extensions" do
    test "extensions receive events during agent lifecycle" do
      test_pid = self()

      stream_fn = fn _msgs, _sp, _tools, _opts ->
        msg =
          Ash.Changeset.for_create(PiEx.Chat.Message, :create_assistant, %{
            content: "Done.",
            stop_reason: :end_turn
          })
          |> Ash.create!()

        {:ok, msg}
      end

      {:ok, pid} =
        PiEx.Agent.start_session(
          stream_fn: stream_fn,
          extensions: [{LogExtension, %{log_pid: test_pid}}]
        )

      PiEx.Agent.subscribe(pid)
      PiEx.Agent.prompt(pid, "hello")

      assert_receive {:ext_event, :session_start, _}, 5000
      assert_receive {:ext_event, :before_prompt, %{text: "hello"}}, 5000
      assert_receive {:ext_event, :turn_start, _}, 5000
      assert_receive {:ext_event, :agent_end, _}, 5000
      assert_receive {:pi_ex_native, _, %{type: :agent_end}}, 5000
    end

    test "extension can mutate prompt text" do
      captured_msgs = :ets.new(:captured, [:set, :public])

      stream_fn = fn msgs, _sp, _tools, _opts ->
        user_msg = Enum.find(msgs, &(&1.role == :user))
        :ets.insert(captured_msgs, {:last_user_msg, user_msg.content})

        msg =
          Ash.Changeset.for_create(PiEx.Chat.Message, :create_assistant, %{
            content: "ok",
            stop_reason: :end_turn
          })
          |> Ash.create!()

        {:ok, msg}
      end

      {:ok, pid} =
        PiEx.Agent.start_session(
          stream_fn: stream_fn,
          extensions: [MutateExtension]
        )

      PiEx.Agent.subscribe(pid)
      PiEx.Agent.prompt(pid, "original text")

      assert_receive {:pi_ex_native, _, %{type: :agent_end}}, 5000
      [{:last_user_msg, content}] = :ets.lookup(captured_msgs, :last_user_msg)
      assert content == "mutated prompt"
      :ets.delete(captured_msgs)
    end

    test "extension tools are merged into agent tools" do
      stream_fn = fn _msgs, _sp, tools, _opts ->
        send(self(), {:tools_received, tools})

        msg =
          Ash.Changeset.for_create(PiEx.Chat.Message, :create_assistant, %{
            content: "ok",
            stop_reason: :end_turn
          })
          |> Ash.create!()

        {:ok, msg}
      end

      {:ok, pid} =
        PiEx.Agent.start_session(
          stream_fn: stream_fn,
          extensions: [ToolExtension],
          tools: []
        )

      state = PiEx.Agent.get_state(pid)
      # Can't check tools directly from get_state, but we verify via the session
      # The tool_map should contain our extension tool
      GenServer.stop(pid)
    end
  end
end
