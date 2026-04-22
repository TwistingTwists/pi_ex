# Agent Loop & Tools Analysis

## The Agent Loop — What It Actually Does

The pi-mono agent loop (`agent-loop.js`, ~300 lines) is a **pure async function** — no classes, no state ownership. The stateful `Agent` class wraps it.

### Loop Structure (2 nested loops)

```
OUTER LOOP: runs until no follow-up messages
  INNER LOOP: runs while there are tool calls OR steering messages
    1. Inject any pending steering messages → emit message events
    2. Call LLM (stream response) → emit message_start/update/end
    3. If error/abort → emit turn_end, agent_end, RETURN
    4. Extract tool_calls from assistant response
    5. Execute tools (parallel or sequential) → emit tool events
    6. Push tool results to context
    7. Check for new steering messages → loop back to step 1
  END INNER
  Check for follow-up messages → if any, set as pending, OUTER continues
END OUTER
emit agent_end
```

### Key Insight: The Loop is Pure
`runAgentLoop(prompts, context, config, emit, signal, streamFn)` takes everything as arguments:
- `prompts` — initial user messages
- `context` — `{systemPrompt, messages, tools}` (mutated in-place during the run)
- `config` — callbacks: `convertToLlm`, `transformContext`, `getSteeringMessages`, `getFollowUpMessages`, `beforeToolCall`, `afterToolCall`
- `emit` — event callback (async, awaited per event)
- `signal` — abort signal
- `streamFn` — the actual LLM streaming function

This means the loop is **fully testable without any LLM** — you just pass a fake `streamFn`.

### Tool Execution Flow
```
For each tool_call in assistant response:
  1. PREPARE: find tool, validate args, run beforeToolCall hook
     → if blocked or error → immediate error result
  2. EXECUTE: call tool.execute(), collect partial updates
  3. FINALIZE: run afterToolCall hook (can mutate result)
  4. EMIT: tool_execution_end event
  5. Create ToolResultMessage, emit message events
```

Parallel mode: prepare sequentially (for ordering), execute concurrently, emit results in original order.

## The Agent (Stateful Wrapper)

`Agent` class owns:
- `_state` — mutable: messages, tools, model, systemPrompt, thinkingLevel, streaming flags
- Message queues — steering (mid-run injection) and follow-up (post-run continuation)
- Event listeners — `Set<(event, signal) => Promise<void>>`, awaited in order
- Active run tracking — abort controller + promise for `waitForIdle()`

Key methods:
- `prompt(input)` → creates user message, calls `runAgentLoop`
- `continue()` → calls `runAgentLoopContinue` (retry from current state)
- `steer(message)` → enqueue for mid-run injection
- `followUp(message)` → enqueue for post-run continuation
- `abort()` → signal abort
- `processEvents(event)` → update internal state + notify listeners

## Minimum Viable Tools for Testing

The tools are **surprisingly simple at their core**. Strip away TUI rendering and you get:

### read (~50 lines of core logic)
- Resolve path (relative to cwd)
- Check if image → return base64 image content
- Read file, split into lines
- Apply offset/limit (1-indexed)
- Truncate to max lines (2000) or max bytes (50KB)
- Return text content

### bash (~80 lines of core logic)
- Spawn child process with command
- Capture stdout + stderr
- Apply timeout (kill on timeout)
- Truncate output (last 2000 lines or 50KB)
- If truncated, write full output to temp file, note it in result
- Return stdout/stderr as text

### write (~30 lines of core logic)
- Resolve path
- Create parent directories
- Write content to file
- Return confirmation text

### edit (~100 lines of core logic)
- Resolve path, read current file
- For each edit: find oldText in file, verify unique match
- Apply replacements (all matched against original, not incremental)
- Write result
- Return diff summary

## Testing Strategy

### Level 1: Pure Loop Tests (no LLM, no tools)
Mock `streamFn` to return canned assistant responses:
```elixir
# Returns text-only response (no tool calls) → loop exits after 1 turn
fake_stream = fn _model, _context, _opts -> 
  stream_events([
    {:start, partial_msg},
    {:text_delta, "Hello!"},
    {:done, final_msg}
  ])
end
```

Test: prompt goes in, events come out, messages accumulate correctly.

### Level 2: Tool Execution Tests (no LLM, real tools)
Mock `streamFn` to return assistant messages WITH tool_calls:
```elixir
# Returns tool call → tool executes → loop calls LLM again → returns text
fake_stream = fn _model, context, _opts ->
  if has_tool_results?(context.messages) do
    text_response("I read the file.")
  else
    tool_call_response("read", %{path: "test.txt"})
  end
end
```

Test: tool calls are extracted, tools execute, results feed back, loop continues.

### Level 3: Steering & Follow-up Tests
Test that mid-run messages inject correctly and follow-up messages extend the run.

### Level 4: Hook Tests
Test `before_tool_call` blocking and `after_tool_call` mutation.

### Level 5: Integration Tests
Real `req_llm` calls against a live API (tagged `@tag :integration`, skipped in CI).

## Mapping to Elixir

| pi-mono | PiEx | Notes |
|---------|------|-------|
| `agentLoop()` pure fn | `PiEx.AgentLoop.run/5` | Pure function, no GenServer |
| `Agent` class | `PiEx.Agent` GenServer | Process per session |
| `emit(event)` callback | `send(subscriber, {:pi_ex, event})` | Or Registry broadcast |
| `AbortSignal` | `Process.exit/2` or flag in state | Check flag between turns |
| `streamFn` | `stream_fn` callback or `PiEx.LLM.stream/3` | Swappable for tests |
| `AgentTool` interface | `PiEx.Tool` behaviour | `execute/3` callback |
| Tool schemas (TypeBox) | `NimbleOptions` or plain maps | For validation |
| `convertToLlm` | `convert_to_llm/1` function | Strip custom messages |
