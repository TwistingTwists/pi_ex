defmodule OrchestratorDemo.AgentRunner do
  @moduledoc """
  Example GenServer that owns and orchestrates a `PiEx` agent session.

  This is the pattern an application can use when it wants PiEx as a library:
  start the agent, subscribe to events, proxy prompts, and keep whatever state
  the host application needs.
  """

  use GenServer

  defstruct [:agent, :session_id, :last_response, events: [], waiters: %{}]

  @type option ::
          {:cwd, Path.t()}
          | {:read_path, String.t()}
          | {:stream_fn, PiEx.Agent.stream_fn()}
          | {:tools, [module()]}

  @doc "Start an orchestrated PiEx session."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Send a prompt to the underlying PiEx agent."
  @spec prompt(GenServer.server(), String.t()) :: :ok
  def prompt(runner, text), do: GenServer.call(runner, {:prompt, text})

  @doc "Return collected PiEx events in chronological order."
  @spec events(GenServer.server()) :: [map()]
  def events(runner), do: GenServer.call(runner, :events)

  @doc "Return the last completed assistant response, if any."
  @spec last_response(GenServer.server()) :: String.t() | nil
  def last_response(runner), do: GenServer.call(runner, :last_response)

  @doc "Wait until the current agent turn finishes."
  @spec await_done(GenServer.server(), timeout()) :: {:ok, String.t()} | {:error, :timeout}
  def await_done(runner, timeout \\ 30_000) do
    GenServer.call(runner, {:await_done, timeout}, timeout + 1_000)
  end

  @impl true
  def init(opts) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    read_path = Keyword.get(opts, :read_path, "sample.txt")

    stream_fn =
      Keyword.get_lazy(opts, :stream_fn, fn ->
        OrchestratorDemo.DemoLLM.stream_fn(read_path: read_path)
      end)

    tools = Keyword.get(opts, :tools, PiEx.Tools.coding_tools())

    with {:ok, agent} <- PiEx.start_session(stream_fn: stream_fn, tools: tools, cwd: cwd),
         :ok <- PiEx.subscribe(agent) do
      {:ok, %__MODULE__{agent: agent, session_id: PiEx.session_id(agent)}}
    end
  end

  @impl true
  def handle_call({:prompt, text}, _from, state) do
    :ok = PiEx.prompt(state.agent, text)
    {:reply, :ok, %{state | last_response: nil}}
  end

  def handle_call(:events, _from, state) do
    {:reply, Enum.reverse(state.events), state}
  end

  def handle_call(:last_response, _from, state) do
    {:reply, state.last_response, state}
  end

  def handle_call({:await_done, _timeout}, _from, %{last_response: response} = state)
      when is_binary(response) do
    {:reply, {:ok, response}, state}
  end

  def handle_call({:await_done, timeout}, from, state) do
    ref = make_ref()
    timer = Process.send_after(self(), {:await_timeout, ref}, timeout)
    {:noreply, %{state | waiters: Map.put(state.waiters, ref, {from, timer})}}
  end

  @impl true
  def handle_info({:pi_ex_native, session_id, event}, %{session_id: session_id} = state) do
    state = %{state | events: [event | state.events]}

    case event do
      %{type: :agent_end, messages: messages} ->
        response = final_assistant_response(messages)
        state = reply_waiters(%{state | last_response: response}, {:ok, response})
        {:noreply, state}

      _event ->
        {:noreply, state}
    end
  end

  def handle_info({:await_timeout, ref}, state) do
    case Map.pop(state.waiters, ref) do
      {{from, _timer}, waiters} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | waiters: waiters}}

      {nil, _waiters} ->
        {:noreply, state}
    end
  end

  defp final_assistant_response(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: :assistant, content: content} when is_binary(content) -> content
      _message -> nil
    end)
  end

  defp reply_waiters(state, reply) do
    Enum.each(state.waiters, fn {_ref, {from, timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, reply)
    end)

    %{state | waiters: %{}}
  end
end
