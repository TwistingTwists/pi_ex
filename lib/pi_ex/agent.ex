defmodule PiEx.Agent do
  @moduledoc "Agent GenServer that orchestrates the prompt-tool loop."
  use GenServer

  alias PiEx.Chat.{Message, Session}
  alias PiEx.Extension.Pipeline
  alias PiEx.Turn

  @type stream_fn :: (list(), String.t(), list(), keyword() ->
                        {:ok, Message.t()} | {:error, term()})

  @type session_opts :: [
          stream_fn: stream_fn(),
          tools: [module()],
          system_prompt: String.t(),
          cwd: String.t(),
          model: String.t(),
          extensions: [module() | {module(), map()}],
          hooks: map(),
          on_event: (map() -> any())
        ]

  # --- Public API ---

  @spec start_session(session_opts()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts \\ []) do
    DynamicSupervisor.start_child(:pi_ex_sessions, {__MODULE__, opts})
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec subscribe(pid()) :: :ok
  def subscribe(pid), do: GenServer.call(pid, :subscribe)

  @spec prompt(pid(), String.t()) :: :ok
  def prompt(pid, text), do: GenServer.cast(pid, {:prompt, text})

  @spec steer(pid(), String.t()) :: :ok
  def steer(pid, text), do: GenServer.cast(pid, {:steer, text})

  @spec abort(pid()) :: :ok
  def abort(pid), do: GenServer.cast(pid, :abort)

  @spec interrupt(pid(), String.t(), keyword()) :: :ok
  def interrupt(pid, text, opts \\ []) do
    mode = Keyword.get(opts, :mode, :graceful)
    GenServer.cast(pid, {:interrupt, text, mode})
  end

  @spec get_state(pid()) :: %{status: atom(), messages: list(), model: String.t() | nil}
  def get_state(pid), do: GenServer.call(pid, :get_state)

  @spec get_session(pid()) :: Session.t()
  def get_session(pid), do: GenServer.call(pid, :get_session)

  # --- Callbacks ---

  @impl true
  def init(opts) do
    tools = Keyword.get(opts, :tools, PiEx.Tools.coding_tools())
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    system_prompt =
      Keyword.get_lazy(opts, :system_prompt, fn ->
        PiEx.SystemPrompt.build(tools: tools, cwd: cwd)
      end)

    model = Keyword.get(opts, :model)

    session =
      Session
      |> Ash.Changeset.for_create(:start, %{
        system_prompt: system_prompt,
        cwd: cwd,
        model: model
      })
      |> Ash.create!()

    extensions = Keyword.get(opts, :extensions, [])

    {ext_entries, all_tools} =
      case Pipeline.init(extensions) do
        {:ok, entries} ->
          ext_tools = Pipeline.collect_tools(entries)
          {entries, Enum.uniq(tools ++ ext_tools)}

        {:error, _reason} ->
          {[], tools}
      end

    hooks = build_hooks_from_extensions(ext_entries, session, Keyword.get(opts, :hooks, %{}))

    state = %{
      session: session,
      stream_fn: Keyword.fetch!(opts, :stream_fn),
      tools: all_tools,
      tool_map: Turn.build_tool_map(all_tools),
      subscribers: MapSet.new(),
      task_ref: nil,
      hooks: hooks,
      ext_entries: ext_entries,
      on_event: Keyword.get(opts, :on_event),
      pending_interrupt: nil
    }

    state = fire_extension_event(state, :session_start, %{})

    {:ok, state}
  end

  @impl true
  def handle_call(:subscribe, {pid, _}, state) do
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call(:get_state, _from, %{session: session} = state) do
    {:reply, %{status: session.status, messages: session.messages, model: session.model}, state}
  end

  def handle_call(:get_session, _from, state) do
    {:reply, state.session, state}
  end

  @impl true
  def handle_cast({:prompt, text}, %{session: %{status: :idle}} = state) do
    # Fire :before_prompt — allows extensions to mutate the prompt text
    {state, payload} = dispatch_extension(state, :before_prompt, %{text: text})
    text = Map.get(payload, :text, text)

    user_msg =
      Message
      |> Ash.Changeset.for_create(:create_user, %{content: text})
      |> Ash.create!()

    state
    |> append_message(user_msg)
    |> set_status(:streaming)
    |> broadcast(%{type: :agent_start})
    |> broadcast(%{type: :turn_start})
    |> fire_extension_event(:turn_start, %{})
    |> spawn_llm_call()
    |> then(&{:noreply, &1})
  end

  def handle_cast({:prompt, _text}, state) do
    broadcast(state, %{type: :error, reason: "Agent is not idle, status: #{state.session.status}"})

    {:noreply, state}
  end

  def handle_cast({:steer, text}, state) do
    session = %{state.session | steering_queue: state.session.steering_queue ++ [text]}
    {:noreply, %{state | session: session}}
  end

  def handle_cast(:abort, %{task_ref: ref} = state) when ref != nil do
    Process.demonitor(ref, [:flush])

    state
    |> set_status(:idle)
    |> Map.put(:task_ref, nil)
    |> broadcast(%{type: :aborted})
    |> fire_extension_event(:agent_end, %{messages: state.session.messages})
    |> broadcast(%{type: :agent_end, messages: state.session.messages})
    |> then(&{:noreply, &1})
  end

  def handle_cast(:abort, state), do: {:noreply, state}

  def handle_cast({:interrupt, text, :graceful}, %{session: %{status: :idle}} = state) do
    # Idle — behave like prompt/2
    user_msg =
      Message
      |> Ash.Changeset.for_create(:create_user, %{content: text})
      |> Ash.create!()

    state
    |> append_message(user_msg)
    |> set_status(:streaming)
    |> broadcast(%{type: :interrupted, mode: :graceful, text: text})
    |> broadcast(%{type: :agent_start})
    |> broadcast(%{type: :turn_start})
    |> spawn_llm_call()
    |> then(&{:noreply, &1})
  end

  def handle_cast({:interrupt, text, :graceful}, state) do
    # Streaming — queue like steer
    session = %{state.session | steering_queue: state.session.steering_queue ++ [text]}
    state = %{state | session: session}
    broadcast(state, %{type: :interrupted, mode: :graceful, text: text})
    {:noreply, state}
  end

  def handle_cast({:interrupt, text, :immediate}, %{session: %{status: :idle}} = state) do
    user_msg =
      Message
      |> Ash.Changeset.for_create(:create_user, %{content: text})
      |> Ash.create!()

    state
    |> append_message(user_msg)
    |> set_status(:streaming)
    |> broadcast(%{type: :interrupted, mode: :immediate, text: text})
    |> broadcast(%{type: :agent_start})
    |> broadcast(%{type: :turn_start})
    |> spawn_llm_call()
    |> then(&{:noreply, &1})
  end

  def handle_cast({:interrupt, text, :immediate}, %{task_ref: ref} = state) when ref != nil do
    Process.demonitor(ref, [:flush])

    user_msg =
      Message
      |> Ash.Changeset.for_create(:create_user, %{content: text})
      |> Ash.create!()

    state
    |> Map.put(:task_ref, nil)
    |> append_message(user_msg)
    |> set_status(:streaming)
    |> broadcast(%{type: :interrupted, mode: :immediate, text: text})
    |> broadcast(%{type: :turn_start})
    |> spawn_llm_call()
    |> then(&{:noreply, &1})
  end

  def handle_cast({:interrupt, text, :immediate}, state) do
    # No task ref but not idle (e.g. executing_tools) — queue as graceful
    session = %{state.session | steering_queue: state.session.steering_queue ++ [text]}
    state = %{state | session: session}
    broadcast(state, %{type: :interrupted, mode: :immediate, text: text})
    {:noreply, state}
  end

  def handle_cast({:interrupt, text, :after_turn}, %{session: %{status: :idle}} = state) do
    # Idle — just start like prompt
    user_msg =
      Message
      |> Ash.Changeset.for_create(:create_user, %{content: text})
      |> Ash.create!()

    state
    |> append_message(user_msg)
    |> set_status(:streaming)
    |> broadcast(%{type: :interrupted, mode: :after_turn, text: text})
    |> broadcast(%{type: :agent_start})
    |> broadcast(%{type: :turn_start})
    |> spawn_llm_call()
    |> then(&{:noreply, &1})
  end

  def handle_cast({:interrupt, text, :after_turn}, state) do
    state = %{state | pending_interrupt: {:after_turn, text}}
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, {:ok, assistant_msg}}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])

    state =
      state
      |> Map.put(:task_ref, nil)
      |> append_message(assistant_msg)
      |> broadcast(%{type: :message_end, message: assistant_msg})

    assistant_msg
    |> Turn.extract_tool_calls()
    |> handle_tool_calls(state)
    |> then(&{:noreply, &1})
  end

  def handle_info({ref, {:error, reason}}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])

    state
    |> Map.put(:task_ref, nil)
    |> set_status(:idle)
    |> broadcast(%{type: :error, reason: reason})
    |> broadcast(%{type: :agent_end, messages: state.session.messages})
    |> then(&{:noreply, &1})
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    state
    |> Map.put(:task_ref, nil)
    |> set_status(:idle)
    |> broadcast(%{type: :error, reason: reason})
    |> broadcast(%{type: :agent_end, messages: state.session.messages})
    |> then(&{:noreply, &1})
  end

  def handle_info({:continue}, state) do
    state
    |> broadcast(%{type: :turn_start})
    |> fire_extension_event(:turn_start, %{})
    |> spawn_llm_call()
    |> then(&{:noreply, &1})
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # --- Private helpers ---

  defp handle_tool_calls([], state) do
    inject_steering_and_maybe_continue(state)
  end

  defp handle_tool_calls(tool_calls, state) when is_list(tool_calls) do
    case state.pending_interrupt do
      {:after_turn, text} ->
        # Skip tool execution, inject interrupt message, re-enter loop
        user_msg =
          Message
          |> Ash.Changeset.for_create(:create_user, %{content: text})
          |> Ash.create!()

        state
        |> Map.put(:pending_interrupt, nil)
        |> append_message(user_msg)
        |> broadcast(%{type: :interrupted, mode: :after_turn, text: text})
        |> broadcast(%{type: :turn_start})
        |> set_status(:streaming)
        |> spawn_llm_call()

      nil ->
        handle_tool_calls_normal(tool_calls, state)
    end
  end

  defp handle_tool_calls_normal(tool_calls, state) do
    context = %{cwd: state.session.cwd}

    state =
      state
      |> set_status(:executing_tools)
      |> broadcast_tool_starts(tool_calls)

    tool_results = Turn.execute_tools(tool_calls, state.tool_map, context, state.hooks)

    state
    |> append_tool_results(tool_results)
    |> broadcast(%{type: :turn_end})
    |> fire_extension_event(:turn_end, %{})
    |> inject_steering()
    |> set_status(:streaming)
    |> broadcast(%{type: :turn_start})
    |> spawn_llm_call()
  end

  defp broadcast_tool_starts(state, tool_calls) do
    Enum.reduce(tool_calls, state, fn tc, acc ->
      broadcast(acc, %{
        type: :tool_start,
        tool_name: tc.name,
        args: tc.arguments,
        tool_call_id: tc.id
      })
    end)
  end

  defp append_tool_results(state, tool_results) do
    Enum.reduce(tool_results, state, fn result, acc ->
      acc
      |> broadcast(%{type: :tool_end, message: result})
      |> append_message(result)
    end)
  end

  defp append_message(state, msg) do
    session = PiEx.Session.append_message(state.session, msg)
    %{state | session: session}
  end

  defp set_status(state, status) do
    %{state | session: %{state.session | status: status}}
  end

  defp spawn_llm_call(state) do
    %{session: session, stream_fn: stream_fn, tools: tools, subscribers: subscribers} = state

    opts = [
      model: session.model,
      cwd: session.cwd,
      caller: self(),
      subscribers: subscribers,
      session_id: session.id
    ]

    task = Task.Supervisor.async(PiEx.TaskSupervisor, fn -> stream_fn.(session.messages, session.system_prompt, tools, opts) end)
    %{state | task_ref: task.ref}
  end

  defp inject_steering(state) do
    case state.session.steering_queue do
      [] ->
        state

      queue ->
        steer_msgs =
          Enum.map(queue, fn text ->
            Message
            |> Ash.Changeset.for_create(:create_user, %{content: text})
            |> Ash.create!()
          end)

        session = %{
          state.session
          | messages: state.session.messages ++ steer_msgs,
            steering_queue: []
        }

        %{state | session: session}
    end
  end

  defp inject_steering_and_maybe_continue(state) do
    case state.session.steering_queue do
      [] ->
        state
        |> set_status(:idle)
        |> fire_extension_event(:agent_end, %{messages: state.session.messages})
        |> broadcast(%{type: :agent_end, messages: state.session.messages})

      _queue ->
        state
        |> inject_steering()
        |> set_status(:streaming)
        |> broadcast(%{type: :turn_start})
        |> spawn_llm_call()
    end
  end

  defp broadcast(state, event) do
    if state.on_event, do: state.on_event.(event)

    for pid <- state.subscribers do
      send(pid, {:pi_ex, state.session.id, event})
    end

    state
  end

  # --- Extension helpers ---

  defp ext_context(session) do
    %{session_id: session.id, cwd: session.cwd, model: session.model}
  end

  defp fire_extension_event(%{ext_entries: []} = state, _event, _payload), do: state

  defp fire_extension_event(state, event_name, payload) do
    {new_entries, _payload} =
      Pipeline.dispatch(state.ext_entries, event_name, payload, ext_context(state.session))

    %{state | ext_entries: new_entries}
  end

  defp dispatch_extension(%{ext_entries: []} = state, _event, payload), do: {state, payload}

  defp dispatch_extension(state, event_name, payload) do
    {new_entries, new_payload} =
      Pipeline.dispatch(state.ext_entries, event_name, payload, ext_context(state.session))

    {%{state | ext_entries: new_entries}, new_payload}
  end

  defp build_hooks_from_extensions([], _session, base_hooks), do: base_hooks

  defp build_hooks_from_extensions(_ext_entries, _session, base_hooks) do
    # Extensions use :tool_call / :tool_result events via pipeline dispatch.
    # We bridge them into the existing hooks interface so Turn doesn't need to change.
    # Base hooks (if any) still take precedence for backwards compatibility.
    base_hooks
  end
end
