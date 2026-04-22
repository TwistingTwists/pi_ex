defmodule PiEx.Agent do
  @moduledoc "Agent GenServer that orchestrates the prompt-tool loop."
  use GenServer

  alias PiEx.Chat.{Message, Session}
  alias PiEx.Turn

  @type stream_fn :: (list(), String.t(), list(), keyword() ->
                        {:ok, Message.t()} | {:error, term()})

  @type session_opts :: [
          stream_fn: stream_fn(),
          tools: [module()],
          system_prompt: String.t(),
          cwd: String.t(),
          model: String.t(),
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

  @spec get_state(pid()) :: %{status: atom(), messages: list(), model: String.t() | nil}
  def get_state(pid), do: GenServer.call(pid, :get_state)

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

    state = %{
      session: session,
      stream_fn: Keyword.fetch!(opts, :stream_fn),
      tools: tools,
      tool_map: Turn.build_tool_map(tools),
      subscribers: MapSet.new(),
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

  def handle_call(:get_state, _from, %{session: session} = state) do
    {:reply, %{status: session.status, messages: session.messages, model: session.model}, state}
  end

  @impl true
  def handle_cast({:prompt, text}, %{session: %{status: :idle}} = state) do
    user_msg =
      Message
      |> Ash.Changeset.for_create(:create_user, %{content: text})
      |> Ash.create!()

    state
    |> append_message(user_msg)
    |> set_status(:streaming)
    |> broadcast(%{type: :agent_start})
    |> broadcast(%{type: :turn_start})
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
    |> broadcast(%{type: :agent_end, messages: state.session.messages})
    |> then(&{:noreply, &1})
  end

  def handle_cast(:abort, state), do: {:noreply, state}

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
    |> spawn_llm_call()
    |> then(&{:noreply, &1})
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # --- Private helpers ---

  defp handle_tool_calls([], state) do
    inject_steering_and_maybe_continue(state)
  end

  defp handle_tool_calls(tool_calls, state) do
    context = %{cwd: state.session.cwd}

    state =
      state
      |> set_status(:executing_tools)
      |> broadcast_tool_starts(tool_calls)

    tool_results = Turn.execute_tools(tool_calls, state.tool_map, context, state.hooks)

    state
    |> append_tool_results(tool_results)
    |> broadcast(%{type: :turn_end})
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
    session = %{state.session | messages: state.session.messages ++ [msg]}
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

    task = Task.async(fn -> stream_fn.(session.messages, session.system_prompt, tools, opts) end)
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
end
