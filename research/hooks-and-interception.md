# Pi Hooks and Interception Architecture

## 1. Tool Call Pipeline: Prepare → Execute → Finalize

The agent-core (`agent-loop.js`) implements a three-phase pipeline for every tool call:

### Phase 1: `prepareToolCall()`
1. Finds the tool in `currentContext.tools`
2. Calls `tool.prepareArguments()` if defined (argument normalization shim)
3. Validates arguments against the TypeBox schema via `validateToolArguments()`
4. Calls `config.beforeToolCall()` hook — can return `{ block: true, reason? }` to prevent execution
5. Returns either `{ kind: "immediate", result, isError }` (blocked/error) or `{ kind: "prepared", toolCall, tool, args }`

### Phase 2: `executePreparedToolCall()`
- Calls `tool.execute(toolCallId, args, signal, onUpdate)` 
- `onUpdate` callback emits `tool_execution_update` events for streaming partial results
- Catches errors and wraps them as error tool results

### Phase 3: `finalizeExecutedToolCall()`
- Calls `config.afterToolCall()` hook with the executed result
- Applies field-by-field merge: `content`, `details`, `isError` (no deep merge)
- If afterToolCall throws, result becomes an error

### Sequential vs Parallel Execution

```
toolExecution: "sequential" | "parallel"  // AgentLoopConfig
executionMode?: "sequential" | "parallel" // per-tool override
```

- **Sequential**: prepare → execute → finalize → emit for each tool call in order
- **Parallel**: prepare all sequentially (beforeToolCall runs serially), then execute concurrently, `tool_execution_end` emits in completion order, tool-result messages emit in source order

## 2. BeforeToolCall Hook

```typescript
interface BeforeToolCallContext {
  assistantMessage: AssistantMessage;
  toolCall: AgentToolCall;       // { type: "toolCall", id, name, arguments }
  args: unknown;                  // validated args
  context: AgentContext;          // { systemPrompt, messages, tools }
}

interface BeforeToolCallResult {
  block?: boolean;
  reason?: string;  // shown in error tool result if blocked
}
```

- Called after argument validation, before execution
- Receives abort signal as second argument
- Return `undefined` or `{}` to allow, `{ block: true }` to prevent
- Blocking produces an error tool result with the reason text

## 3. AfterToolCall Hook

```typescript
interface AfterToolCallContext {
  assistantMessage: AssistantMessage;
  toolCall: AgentToolCall;
  args: unknown;
  result: AgentToolResult<any>;   // { content, details }
  isError: boolean;
  context: AgentContext;
}

interface AfterToolCallResult {
  content?: (TextContent | ImageContent)[];  // replaces full array
  details?: unknown;                          // replaces full value
  isError?: boolean;                          // replaces flag
}
```

- Field-by-field replacement, no deep merge
- Omitted fields keep original values
- If the hook throws, result becomes an error

## 4. Extension Event System

### All Events (30+)

| Event | Can Return | Semantics |
|-------|-----------|-----------|
| `resources_discover` | `ResourcesDiscoverResult` | Provide skill/prompt/theme paths |
| `session_start` | void | Session loaded/created |
| `session_before_switch` | `{ cancel? }` | Can prevent session switch |
| `session_before_fork` | `{ cancel?, skipConversationRestore? }` | Can prevent fork |
| `session_before_compact` | `{ cancel?, compaction? }` | Can prevent/replace compaction |
| `session_compact` | void | After compaction |
| `session_shutdown` | void | Before teardown |
| `session_before_tree` | `{ cancel?, summary?, ... }` | Can prevent tree navigation |
| `session_tree` | void | After tree navigation |
| `context` | `{ messages? }` | Transform messages before LLM call (chained) |
| `before_provider_request` | replacement payload | Modify raw API payload (chained) |
| `after_provider_response` | void | Observe response headers/status |
| `before_agent_start` | `{ message?, systemPrompt? }` | Inject messages, modify system prompt |
| `agent_start` | void | Agent loop started |
| `agent_end` | void | Agent loop ended |
| `turn_start` | void | New turn |
| `turn_end` | void | Turn complete |
| `message_start` | void | Message begins |
| `message_update` | void | Streaming token update |
| `message_end` | void | Message complete |
| `tool_execution_start` | void | Tool begins executing |
| `tool_execution_update` | void | Tool streaming partial result |
| `tool_execution_end` | void | Tool finished |
| `model_select` | void | Model changed |
| `tool_call` | `{ block?, reason? }` | **Before tool execution, can block. Input is mutable.** |
| `tool_result` | `{ content?, details?, isError? }` | **After tool execution, can modify result (chained)** |
| `user_bash` | `{ operations?, result? }` | Intercept user `!` bash commands |
| `input` | `"continue" | "transform" | "handled"` | Transform/intercept user input |

### Handler Execution Model

All handlers are **async** and executed **sequentially** across extensions (extension load order matters). Key patterns:

- **Chaining**: `context`, `before_provider_request`, `tool_result`, `input` — each handler sees previous handler's modifications
- **Short-circuit blocking**: `tool_call`, `session_before_*` — returning `{ block/cancel: true }` stops further handlers
- **Fire-and-forget**: `agent_start`, `message_*`, `tool_execution_*` — no return value used
- **Accumulating**: `before_agent_start`, `resources_discover` — results collected from all handlers

### How Session Wires tool_call/tool_result to Agent-Core Hooks

In `agent-session.js`, `_installAgentToolHooks()`:

```typescript
// beforeToolCall → emitToolCall (tool_call event)
this.agent.beforeToolCall = async ({ toolCall, args }) => {
  const runner = this._extensionRunner;
  if (!runner.hasHandlers("tool_call")) return undefined;
  await this._agentEventQueue;  // wait for pending event processing
  return await runner.emitToolCall({
    type: "tool_call", toolName: toolCall.name,
    toolCallId: toolCall.id, input: args,
  });
};

// afterToolCall → emitToolResult (tool_result event)  
this.agent.afterToolCall = async ({ toolCall, args, result, isError }) => {
  const runner = this._extensionRunner;
  if (!runner.hasHandlers("tool_result")) return undefined;
  const hookResult = await runner.emitToolResult({
    type: "tool_result", toolName: toolCall.name,
    toolCallId: toolCall.id, input: args,
    content: result.content, details: result.details, isError,
  });
  return hookResult ? { content: hookResult.content, details: hookResult.details,
    isError: hookResult.isError ?? isError } : undefined;
};
```

Key detail: `tool_call` event's `input` is **mutable** — extensions can mutate `event.input` in-place to patch arguments (no re-validation after mutation).

## 5. Extension API Surface

The `ExtensionAPI` (passed as `pi` to extension factories) provides:

### Event Subscription
```typescript
pi.on("tool_call", async (event, ctx) => { ... });
```

### Tool Registration
```typescript
pi.registerTool({
  name: string, label: string, description: string,
  parameters: TSchema,  // TypeBox schema
  execute: (toolCallId, params, signal, onUpdate, ctx) => Promise<AgentToolResult>,
  renderCall?: (args, theme, context) => Component,
  renderResult?: (result, options, theme, context) => Component,
  promptSnippet?: string,      // added to system prompt "Available tools"
  promptGuidelines?: string[], // added to system prompt "Guidelines"
  executionMode?: "sequential" | "parallel",
  renderShell?: "default" | "self",
});
```

### Commands, Shortcuts, Flags
```typescript
pi.registerCommand("mycommand", { description, handler, getArgumentCompletions? });
pi.registerShortcut("ctrl+k", { description, handler });
pi.registerFlag("my-flag", { type: "boolean", default: false, description });
pi.getFlag("my-flag");
```

### Messaging
```typescript
pi.sendMessage(message, { triggerTurn?, deliverAs?: "steer" | "followUp" | "nextTurn" });
pi.sendUserMessage(content, { deliverAs?: "steer" | "followUp" });
pi.appendEntry(customType, data);  // session persistence, not sent to LLM
```

### Model/Tool Management
```typescript
pi.setModel(model);
pi.getActiveTools() / pi.setActiveTools(names) / pi.getAllTools();
pi.getThinkingLevel() / pi.setThinkingLevel(level);
pi.registerProvider(name, config);  // full provider registration with models, OAuth, etc.
pi.unregisterProvider(name);
```

### Session
```typescript
pi.setSessionName(name) / pi.getSessionName();
pi.setLabel(entryId, label);
pi.getCommands();
```

### Utilities
```typescript
pi.exec(command, args, options);  // shell execution
pi.events;  // EventBus for cross-extension communication
```

### Message Rendering
```typescript
pi.registerMessageRenderer(customType, (message, options, theme) => Component);
```

## 6. Event Bus

Simple pub/sub for cross-extension communication:

```typescript
// event-bus.js
function createEventBus() {
  const emitter = new EventEmitter();
  return {
    emit: (channel, data) => emitter.emit(channel, data),
    on: (channel, handler) => {
      const safeHandler = async (data) => {
        try { await handler(data); }
        catch (err) { console.error(`Event handler error (${channel}):`, err); }
      };
      emitter.on(channel, safeHandler);
      return () => emitter.off(channel, safeHandler);  // returns unsubscribe fn
    },
    clear: () => emitter.removeAllListeners(),
  };
}
```

- Untyped string channels
- Async handlers with error swallowing
- Returns unsubscribe function from `on()`
- Exposed as `pi.events` in ExtensionAPI
- Cleared on session shutdown/reload

## 7. Extension Loading & Runtime

### Loader (`loader.js` / `wrapper.js`)
- Extensions are ES modules exporting an `ExtensionFactory`: `(pi: ExtensionAPI) => void | Promise<void>`
- Loader creates a shared `ExtensionRuntime` with throwing stub actions
- Each extension gets its own `ExtensionAPI` wrapper that captures registrations into an `Extension` object
- Provider registrations are queued during loading

### Runner (`runner.js`)
- `ExtensionRunner` holds all loaded extensions and the shared runtime
- `bindCore(actions, contextActions)` replaces stubs with real implementations
- `bindCommandContext(actions)` adds session control methods
- `setUIContext()` provides UI primitives
- Specialized emit methods: `emit()`, `emitToolCall()`, `emitToolResult()`, `emitContext()`, `emitBeforeProviderRequest()`, `emitBeforeAgentStart()`, `emitResourcesDiscover()`, `emitInput()`
- Each has different chaining/short-circuit semantics

### Extension Lifecycle
1. **Load**: Extensions discovered, imported, factory called → registrations captured
2. **Bind**: Runner bound to session with real action implementations
3. **Session start**: `session_start` event fired
4. **Runtime**: Events flow, tools execute
5. **Shutdown**: `session_shutdown` event fired, event bus cleared

## 8. Key Patterns for Elixir

### What to Replicate

1. **Three-phase tool pipeline** (prepare → execute → finalize) — clean separation of concerns, maps well to GenServer callbacks or middleware pipeline
2. **BeforeToolCall as gatekeeper** — blocking with reason, argument mutation
3. **AfterToolCall as result transformer** — field-by-field merge semantics
4. **Extension event system with typed events** — Elixir's pattern matching on event structs is even better than TypeScript discriminated unions
5. **Sequential handler execution with chaining** — important for predictable behavior
6. **Separate emit methods for different semantics** — `emitToolCall` (short-circuit), `emitToolResult` (chaining), `emitContext` (chaining), `emit` (fire-and-forget or cancel)

### What to Do Differently

1. **Use behaviours instead of factory functions** — Elixir `@behaviour Extension` with `@impl` callbacks instead of `pi.on()` registration
2. **Use GenServer/process model** — Each extension as a supervised process, natural error isolation (no try/catch wrapping)
3. **Typed event bus with Phoenix.PubSub or Registry** — Instead of untyped string channels, use structured topics
4. **Pattern matching for event dispatch** — `handle_event(%ToolCall{tool_name: "bash"} = event, state)` instead of runtime type checking
5. **Supervision tree for extension lifecycle** — DynamicSupervisor for extensions, clean restart on failure
6. **Immutable message passing** — No mutable `event.input` — return modified args explicitly
7. **Pipeline as middleware stack** — Tool execution as a `Plug`-style pipeline with `halt()` semantics for blocking
8. **ETS for shared state** — Instead of runtime object mutation, use ETS tables for tool/command registries
