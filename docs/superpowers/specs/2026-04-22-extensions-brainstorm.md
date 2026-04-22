# pi_ex Extensions — Brainstorm & Open Questions

Date: 2026-04-22

## Context

pi-mono (TypeScript) has a rich extension system: 30+ event types, tool/command/shortcut/provider registration, UI primitives, dynamic `.ts` file loading via jiti. pi_ex is an Elixir library (not a CLI) with an OTP-native architecture — GenServer agent loop, DynamicSupervisor for sessions, Ash embedded resources, and a minimal hooks system (`before_tool_call`/`after_tool_call` in `Turn`).

We want extensions in pi_ex. But pi_ex is a different system — a library, not an interactive CLI — so the design should be idiomatic Elixir/OTP, not a port of the TypeScript extension loader.

## What pi-mono's extension system actually does

The pi-mono `ExtensionAPI` gives extensions these capabilities:

1. **Event subscription** — 30+ lifecycle events (session_start, context, before_agent_start, turn_start/end, message_start/update/end, tool_call, tool_result, agent_start/end, model_select, input, etc.)
2. **Tool registration** — define new LLM-callable tools with schema, execution, and custom TUI rendering
3. **Command registration** — slash commands with argument completion
4. **Provider registration** — add/override LLM providers and models at runtime
5. **Message injection** — send custom/user messages, append session entries
6. **Context mutation** — modify messages before LLM call (`context` event), replace system prompt per-turn (`before_agent_start`)
7. **UI primitives** — select, confirm, input, notify, custom components, widgets, footer/header, theme control (TUI-specific, not relevant for pi_ex)

The system prompt bootstraps extension-writing knowledge by pointing the LLM at absolute file paths to pi's own docs — the agent reads `docs/extensions.md` and `examples/extensions/` on demand.

## What pi_ex already has

- `PiEx.Tool` behaviour — `name/0`, `description/0`, `parameters/0`, `execute/2`
- Hooks map in `Agent` GenServer — `before_tool_call`, `after_tool_call` (passed through to `Turn.execute_tools`)
- Event broadcasting — `broadcast/2` sends events to subscriber pids via `send/2`
- System prompt builder — supports tools, context files, skills, custom/append prompts

## Key design question: Who are extensions for?

pi-mono's extensions serve two audiences: (a) the human user who drops `.ts` files to customize their agent, and (b) the LLM itself which discovers skills/tools via the system prompt.

For pi_ex, the target could be:

### Option A: Elixir developers only (compile-time)

Extensions are Elixir modules implementing a behaviour, passed at session startup. No dynamic loading. This is the most OTP-idiomatic approach.

```elixir
PiEx.start_session(
  stream_fn: stream_fn,
  extensions: [MyApp.GitExtension, MyApp.LintExtension]
)
```

**Pros:** Simple, type-safe, testable, no sandboxing needed, leverages OTP patterns naturally.
**Cons:** No runtime discovery, no drop-a-file workflow for end users.

### Option B: Runtime-loadable (like pi-mono)

Extensions are `.ex`/`.exs` files discovered from `~/.pi_ex/extensions/` and `.pi_ex/extensions/`, loaded via `Code.eval_file` or `Code.compile_file`.

**Pros:** Matches pi-mono's UX, enables end-user customization.
**Cons:** Security concerns with `Code.eval_file`, harder to test, un-Elixir-ish.

### Option C: Both layers

A behaviour-based API for Elixir devs (Option A) + a thin runtime loader that compiles `.exs` scripts into modules implementing the behaviour (Option B). The runtime loader is optional — library consumers who don't need it never touch it.

**Pros:** Best of both. Library stays clean, runtime loading is opt-in.
**Cons:** More surface area to maintain.

## Proposed event set (subset of pi-mono, adapted)

Not all of pi-mono's 30+ events make sense for a headless library. Proposed core set:

| Event | Description | Can mutate? |
|-------|-------------|-------------|
| `session_start` | Session initialized | No |
| `before_prompt` | User prompt received, before agent loop | System prompt, message |
| `context` | Messages assembled for LLM call | Messages list |
| `turn_start` | New LLM call starting | No |
| `turn_end` | LLM response received | No |
| `tool_call` | Before tool execution | Block, mutate args |
| `tool_result` | After tool execution | Mutate content |
| `agent_end` | Agent loop finished | No |
| `session_shutdown` | Session terminating | No |

## Proposed extension behaviour sketch

```elixir
defmodule PiEx.Extension do
  @type event :: {atom(), map()}
  @type context :: %{session: Session.t(), cwd: String.t(), model: String.t() | nil}

  @callback init(config :: map()) :: {:ok, state :: term()} | {:error, term()}
  @callback handle_event(event(), context(), state :: term()) ::
              {:ok, state} | {:mutate, changes :: map(), state} | {:block, reason :: String.t(), state}
  @callback tools() :: [module()]  # additional tools to register
  @optional_callbacks [tools: 0]
end
```

## Next steps

1. **Answer the consumer question** — Option A, B, or C?
2. Design the event dispatch pipeline in the Agent GenServer
3. Define how extensions register tools (and how those tools appear in the system prompt)
4. Define context mutation semantics (ordering, conflict resolution)
5. Decide on session persistence hooks (extensions that want to persist state across sessions)

## Decision: Option C — Both layers

**Compile-time:** Elixir modules implementing `PiEx.Extension` behaviour, passed at session startup.
**Runtime:** Optional loader that discovers `.exs` files from `~/.pi_ex/extensions/` and `.pi_ex/extensions/`, compiles them into modules implementing the same behaviour. Library consumers opt in.

The behaviour is the single interface. Runtime loading is sugar on top.
