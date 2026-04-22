# PiEx

An Elixir library for building AI coding agents. OTP-native, with a tool system,
extension pipeline, interrupt API, and session persistence.

## Features

- **Agent loop** — GenServer-based agent that manages LLM ↔ tool execution cycles
- **Tool system** — Built-in `read`, `write`, `edit`, `bash` tools; define custom tools with `PiEx.Tool`
- **Extensions** — Hook into the agent lifecycle (`before_prompt`, `after_turn`, etc.) via `PiEx.Extension`
- **Interrupt API** — Graceful, immediate, or after-turn interruption of running agents
- **Session persistence** — Save/restore sessions as JSONL files
- **Registry events** — Subscribe to agent events with standard OTP Registry broadcasting

## Installation

Add `pi_ex_native` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pi_ex_native, "~> 0.1.0"}
  ]
end
```

## Quick start

```elixir
# Start an agent session
{:ok, pid} = PiEx.start_session(model: "anthropic/claude-sonnet-4-20250514", cwd: ".")

# Subscribe to events
PiEx.subscribe(pid)

# Send a prompt
PiEx.prompt(pid, "Read mix.exs and list the dependencies")

# Receive events
receive do
  {:agent_event, _pid, %{type: :turn_complete, response: response}} ->
    IO.puts(response.content)
after
  30_000 -> IO.puts("timeout")
end
```

## Wrapping in a GenServer

In production apps, wrap PiEx in your own GenServer to own the lifecycle and fan out events:

```elixir
defmodule MyApp.AgentSession do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

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

  def handle_info({:pi_ex, _session_id, event}, state) do
    # Process, store, or broadcast events to LiveView, etc.
    {:noreply, %{state | events: [event | state.events]}}
  end
end
```

## Extensions

Extensions hook into the agent lifecycle:

```elixir
defmodule MyApp.LogExtension do
  @behaviour PiEx.Extension

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def call(:before_prompt, data, state) do
    IO.puts("Prompt: #{data.text}")
    {:cont, data, state}
  end

  def call(_hook, data, state), do: {:cont, data, state}
end

{:ok, pid} = PiEx.start_session(extensions: [MyApp.LogExtension])
```

## Interrupts

Interrupt a running agent with different modes:

```elixir
# Wait for the current tool to finish, then stop
PiEx.interrupt(pid, "User requested stop", mode: :graceful)

# Stop immediately, cancel in-flight work
PiEx.interrupt(pid, "Emergency stop", mode: :immediate)

# Finish the current turn, then stop
PiEx.interrupt(pid, "Wrap up after this turn", mode: :after_turn)
```

## License

MIT — see [LICENSE](LICENSE).
