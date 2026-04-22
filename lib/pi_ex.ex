defmodule PiEx do
  @moduledoc """
  An Elixir library for building AI coding agents.

  PiEx provides an OTP-native agent loop that manages LLM interactions, tool execution,
  extensions, interrupts, and session persistence. Each agent runs as a supervised
  GenServer process with Registry-based event broadcasting.

  ## Quick start

      {:ok, pid} = PiEx.start_session(model: "anthropic/claude-sonnet-4-20250514", cwd: ".")
      PiEx.subscribe(pid)
      PiEx.prompt(pid, "Read mix.exs and summarize the project")

      receive do
        {:agent_event, _pid, %{type: :turn_complete, response: response}} ->
          IO.puts(response.content)
      end

  ## Wrapping in a GenServer (real-world pattern)

  In production, wrap PiEx in your own GenServer to manage lifecycle and fan out events:

      defmodule MyApp.AgentSession do
        use GenServer

        def start_link(opts) do
          GenServer.start_link(__MODULE__, opts)
        end

        def init(opts) do
          {:ok, pid} = PiEx.start_session(
            stream_fn: PiEx.LLM.stream_fn(model: opts[:model]),
            tools: PiEx.Tools.coding_tools(),
            cwd: opts[:cwd]
          )
          PiEx.subscribe(pid)
          PiEx.prompt(pid, opts[:prompt])
          {:ok, %{agent: pid, events: []}}
        end

        def handle_info({:pi_ex_native, _session_id, event}, state) do
          # process or broadcast events
          {:noreply, %{state | events: [event | state.events]}}
        end
      end

  ## Key functions

  - `start_session/1` — start a new agent process
  - `prompt/2` — send a user prompt
  - `steer/2` — inject guidance mid-run
  - `interrupt/3` — interrupt with `:graceful`, `:immediate`, or `:after_turn` mode
  - `abort/1` — abort the current operation
  - `subscribe/1` — subscribe to session events via Registry
  - `get_state/1` / `get_session/1` — inspect agent state
  - `session_id/1` — get the session ID
  """

  @doc "Start a new agent session."
  defdelegate start_session(opts \\ []), to: PiEx.Agent

  @doc "Send a prompt to the agent."
  defdelegate prompt(pid, text), to: PiEx.Agent

  @doc "Steer the agent mid-run."
  defdelegate steer(pid, text), to: PiEx.Agent

  @doc "Abort the current operation."
  defdelegate abort(pid), to: PiEx.Agent

  @doc "Subscribe to session events."
  defdelegate subscribe(pid), to: PiEx.Agent

  @doc "Get the current session state."
  defdelegate get_state(pid), to: PiEx.Agent

  @doc "Get the full session struct."
  defdelegate get_session(pid), to: PiEx.Agent

  @doc "Interrupt the agent. Mode can be `:graceful`, `:immediate`, or `:after_turn`."
  defdelegate interrupt(pid, text, opts \\ []), to: PiEx.Agent

  @doc "Get the session ID for an agent process."
  defdelegate session_id(pid), to: PiEx.Agent
end
