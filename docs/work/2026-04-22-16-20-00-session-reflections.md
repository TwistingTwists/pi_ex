# Session Reflections — PiEx v0 Build

**Date:** 2026-04-22
**Duration:** ~1 hour of active orchestration
**Result:** 63 tests, 8 commits, working agentic loop with streaming, tools, hooks, system prompt, Ash resources

---

## Steering Moments (Abhishek's Preferences)

These are the points where the user corrected course. Each reveals a preference for how Elixir codebases should be built.

### 1. "Think in terms of Elixir, not JS"

After the initial plan mapped pi-mono patterns 1:1, Abhishek pushed back: *"Elixir gives us things out of the box. We don't have to rely on the models of the JS ecosystem."*

**Lesson:** Don't port. Translate. The agent loop in JS exists as a pure function + class wrapper because JS is single-threaded. In Elixir, a GenServer IS the session — the mailbox IS the event queue, killing a Task IS abort. Start from OTP primitives, not from JS patterns.

### 2. "Use Ash for data models — all structs should be Ash resources"

When I initially used `defstruct` for Agent state, Abhishek flagged it: *"Why is PiEx.Agent a defstruct? Ideally all defstruct can be an Ash Resource. Functions can be exposed as Ash actions."*

**Lesson:** In an Ash-first codebase, data structures are resources, not plain structs. This buys: validations on creation, actions as the API, and future data layer swaps (add SQLite later without changing calling code). Runtime-only things (functions, pids, task refs) stay in plain maps — but anything that describes state or could be persisted belongs in Ash.

### 3. "JSONL or SQLite, with id/parentId tree"

When asked about persistence, Abhishek chose the tree model: *"We do want id and parentId kind of approach. That way later if we do SQLite persistence layer, we can."*

**Lesson:** Design for the future data layer even before it exists. An append-only tree with id/parentId works in-memory, in JSONL, and in SQLite. The Ash embedded resource pattern means the swap is mechanical, not architectural.

### 4. "Run it, test it, verify it creates files"

When tools appeared to work but hadn't been end-to-end tested, Abhishek asked for a non-interactive mode (`claude -p` style) and demanded verification: *"Can you write a script so that you can test all four tools?"*

**Lesson:** Working code means code that's been observed working. Scripts that exercise the full loop (LLM → tool calls → file changes → verify) are more valuable than unit tests alone for agentic systems where the integration is the product.

### 5. "Debug with Logger.debug on"

When streaming tool calls had empty arguments, Abhishek said: *"Can you run it in a more of a debug fashion?"* then *"With logger debug on."*

**Lesson:** When debugging LLM integrations, inspect the raw stream. The bug was that `ReqLLM.StreamResponse` sends tool call arguments as `:meta` chunks with `tool_call_args` fragments, not on the `:tool_call` chunk itself. No amount of type-level reasoning would have caught this — you need to see the actual chunks.

### 6. "Pick idiomatic Elixir patterns from reference codebase"

Abhishek pointed to `claude-elixir-phoenix` as a source of patterns, but specified: *"Pick only the ones meant for you (non-Phoenix, non-LiveView)."*

**Lesson:** Reference codebases are pattern libraries, not templates. Cherry-pick what applies. From the Elixir iron laws, the relevant ones for a lib: wrap third-party APIs (Iron Law #20), supervise all long-lived processes (#14), processes model concurrency not code structure (#13), `with` chains over nested `case`, pipeline operators, pattern matching in function heads.

---

## Patterns Picked Up from claude-elixir-phoenix

### Applied

| Pattern | Where Applied |
|---------|--------------|
| `@type` and `@spec` on public API | `PiEx.Agent` public functions |
| Pipeline operators (`\|>` chains) | Agent state updates: `state \|> append_message(msg) \|> set_status(:streaming) \|> broadcast(event)` |
| Pattern matching in function heads | `handle_cast({:prompt, text}, %{session: %{status: :idle}} = state)` |
| `with` chains over nested `case` | Turn logic, message handling |
| Extract helper functions | `handle_tool_calls/2`, `append_tool_results/2`, `set_status/2` |
| Wrap third-party APIs | `PiEx.LLM` wraps `ReqLLM`, tools wrap `File`/`System` |
| Supervise all long-lived processes | DynamicSupervisor for agent sessions |

### Not Applied (Phoenix/LiveView-specific)

- `assign_async` patterns (LiveView only)
- Streams for large lists (LiveView assigns)
- `connected?/1` checks (LiveView only)
- Ecto iron laws (we use Ash, not raw Ecto)
- Oban patterns (no job processing)

### Noted for Later

- **Iron Law #22 "Verify before claiming done"** — we do this with `mix test` and integration scripts
- **Iron Law #16 `@external_resource`** — relevant if we add compile-time file reading for skills
- **Elegance Reset pattern** — useful prompt: "knowing everything you know now, implement the idiomatic Elixir solution"

---

## Orchestration Observations

### What Worked Well

1. **Phase A/B parallelism** — WP1 (Ash resources) and WP2 (tools) had zero dependencies, ran in parallel, completed in ~1.5 min each. Phase B (turn logic + agent) followed immediately.

2. **Giving agents exact interfaces to code against** — WP4 (Agent) was dispatched with WP3's (Turn) exact function signatures before WP3 completed. Both finished and integrated cleanly.

3. **Research agents writing to files** — Three parallel research agents each wrote comprehensive MD files. I read them and formed implementation plans. No context pollution in the orchestrator session.

4. **Integration test scripts** — `scripts/test_tools.exs` caught the streaming tool call args bug that unit tests didn't.

### What Could Improve

1. **First LLM integration was broken** — `api_key` vs `access_token` in ReqLLM provider options. Should have checked the provider's option schema before dispatching.

2. **Streaming required understanding ReqLLM internals** — The `to_response` after consuming the stream fails (GenServer dead). Had to understand the chunk types. A thin `PiEx.LLM` test against a mock server would have caught this earlier.

3. **Agent refactor was straightforward but could have been designed in from the start** — if we'd used Ash resources for Agent state from day 1, we wouldn't have needed the refactor commit.

---

## Architecture Decisions Made

| Decision | Rationale |
|----------|-----------|
| GenServer per session, not per tool | Tools are stateless functions called via Task. Only the session needs process isolation. |
| Ash embedded resources, no data layer yet | Get validations and structure now. Add SQLite later without changing callers. |
| `stream_fn` as the LLM abstraction | Makes the entire agent loop testable with fake functions. Production wires in ReqLLM. |
| Hooks as plain functions, not behaviours | Lightweight for v0. Behaviours/extension system can wrap these later. |
| Subscribers as MapSet of pids | Simple, zero-dep. Phoenix.PubSub or Registry dispatch can replace later. |
| JSONL with tree structure | Matches pi-mono. Append-only is simple. Tree enables branching without data loss. |

---

## Next Session Priorities

1. Verify session persistence implementation (waiting on subagent)
2. Test JSONL round-trip with real agent sessions
3. Consider: auto-save after each turn? Or explicit save only?
4. Consider: session resume (load JSONL → continue prompting)
