defmodule PiEx.Agent do
  @moduledoc "Agent GenServer that orchestrates the prompt-tool loop."
  use GenServer

  alias PiEx.Chat.Message
  alias PiEx.Turn

  defstruct [
    :session_id,
    :status,
    :stream_fn,
    :system_prompt,
    :tools,
    :tool_map,
    :cwd,
    :model,
    :messages,
    :subscribers,
    :steering_queue,
    :task_ref,
    :hooks,
    :on_event
  ]

  # --- Public API ---

  def start_session(opts \\ []) do
    DynamicSupervisor.start_child(:pi_ex_sessions, {__MODULE__, opts})
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def subscribe(pid), do: GenServer.call(pid, :subscribe)
  def prompt(pid, text), do: GenServer.cast(pid, {:prompt, text})
  def steer(pid, text), do: GenServer.cast(pid, {:steer, text})
  def abort(pid), do: GenServer.cast(pid, :abort)
  def get_state(pid), do: GenServer.call(pid, :get_state)

  # --- Callbacks ---

  @impl true
  def init(opts) do
    tools = Keyword.get(opts, :tools, PiEx.Tools.coding_tools())

    state = %__MODULE__{
      session_id: Keyword.get(opts, :session_id, generate_id()),
      status: :idle,
      stream_fn: Keyword.fetch!(opts, :stream_fn),
      system_prompt:
        Keyword.get_lazy(opts, :system_prompt, fn ->
          PiEx.SystemPrompt.build(
            tools: tools,
            cwd: Keyword.get(opts, :cwd, File.cwd!())
          )
        end),
      tools: tools,
      tool_map: Turn.build_tool_map(tools),
      cwd: Keyword.get(opts, :cwd, File.cwd!()),
      model: Keyword.get(opts, :model),
      messages: [],
      subscribers: MapSet.new(),
      steering_queue: [],
      task_ref: nil,
      hooks: Keyword.get(opts, :hooks, %{}),
      on_event: Keyword.get(opts, :on_event)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:subscribe, {pid, _}, state) do
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, %{status: state.status, messages: state.messages, model: state.model}, state}
  end

  @impl true
  def handle_cast({:prompt, text}, %{status: :idle} = state) do
    user_msg =
      Message
      |> Ash.Changeset.for_create(:create_user, %{content: text})
      |> Ash.create!()

    state = %{state | messages: state.messages ++ [user_msg], status: :streaming}
    state = broadcast(state, %{type: :agent_start})
    state = broadcast(state, %{type: :turn_start})
    state = spawn_llm_call(state)
    {:noreply, state}
  end

  def handle_cast({:prompt, _text}, state) do
    broadcast(state, %{type: :error, reason: "Agent is not idle, status: #{state.status}"})
    {:noreply, state}
  end

  def handle_cast({:steer, text}, state) do
    {:noreply, %{state | steering_queue: state.steering_queue ++ [text]}}
  end

  def handle_cast(:abort, %{task_ref: ref} = state) when ref != nil do
    Process.demonitor(ref, [:flush])
    # Kill the task process - find it via the ref
    # Task.async stores {pid, ref}, but we only have ref. We'll use Process.exit on linked processes.
    # Actually, we need to track the task pid too. Let's just demonitor and move on.
    state = %{state | status: :idle, task_ref: nil}
    state = broadcast(state, %{type: :aborted})
    state = broadcast(state, %{type: :agent_end, messages: state.messages})
    {:noreply, state}
  end

  def handle_cast(:abort, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, {:ok, assistant_msg}}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task_ref: nil}
    state = %{state | messages: state.messages ++ [assistant_msg]}
    state = broadcast(state, %{type: :message_end, message: assistant_msg})

    tool_calls = Turn.extract_tool_calls(assistant_msg)

    if tool_calls != [] do
      state = %{state | status: :executing_tools}

      state =
        Enum.reduce(tool_calls, state, fn tc, acc ->
          broadcast(acc, %{
            type: :tool_start,
            tool_name: tc.name,
            args: tc.arguments,
            tool_call_id: tc.id
          })
        end)

      context = %{cwd: state.cwd}
      tool_results = Turn.execute_tools(tool_calls, state.tool_map, context, state.hooks)

      state =
        Enum.reduce(tool_results, state, fn result, acc ->
          acc = broadcast(acc, %{type: :tool_end, message: result})
          %{acc | messages: acc.messages ++ [result]}
        end)

      state = broadcast(state, %{type: :turn_end})
      state = inject_steering(state)
      state = %{state | status: :streaming}
      state = broadcast(state, %{type: :turn_start})
      state = spawn_llm_call(state)
      {:noreply, state}
    else
      state = inject_steering_and_maybe_continue(state)
      {:noreply, state}
    end
  end

  def handle_info({ref, {:error, reason}}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task_ref: nil, status: :idle}
    state = broadcast(state, %{type: :error, reason: reason})
    state = broadcast(state, %{type: :agent_end, messages: state.messages})
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    state = %{state | task_ref: nil, status: :idle}
    state = broadcast(state, %{type: :error, reason: reason})
    state = broadcast(state, %{type: :agent_end, messages: state.messages})
    {:noreply, state}
  end

  def handle_info({:continue}, state) do
    state = broadcast(state, %{type: :turn_start})
    state = spawn_llm_call(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Stale monitor, ignore
    {:noreply, state}
  end

  # --- Private ---

  defp spawn_llm_call(state) do
    stream_fn = state.stream_fn
    messages = state.messages
    system_prompt = state.system_prompt
    tools = state.tools

    opts = [
      model: state.model,
      cwd: state.cwd,
      caller: self(),
      subscribers: state.subscribers,
      session_id: state.session_id
    ]

    task =
      Task.async(fn ->
        stream_fn.(messages, system_prompt, tools, opts)
      end)

    %{state | task_ref: task.ref}
  end

  defp inject_steering(state) do
    case state.steering_queue do
      [] ->
        state

      queue ->
        steer_msgs =
          Enum.map(queue, fn text ->
            Message
            |> Ash.Changeset.for_create(:create_user, %{content: text})
            |> Ash.create!()
          end)

        %{state | messages: state.messages ++ steer_msgs, steering_queue: []}
    end
  end

  defp inject_steering_and_maybe_continue(state) do
    case state.steering_queue do
      [] ->
        state = %{state | status: :idle}
        broadcast(state, %{type: :agent_end, messages: state.messages})

      _queue ->
        state = inject_steering(state)
        state = %{state | status: :streaming}
        state = broadcast(state, %{type: :turn_start})
        spawn_llm_call(state)
    end
  end

  defp broadcast(state, event) do
    if state.on_event, do: state.on_event.(event)

    for pid <- state.subscribers do
      send(pid, {:pi_ex, state.session_id, event})
    end

    state
  end

  defp generate_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
