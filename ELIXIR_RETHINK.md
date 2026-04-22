# PiEx — Elixir-Native Rethink

The JS agent loop exists the way it does because of JS limitations. Elixir gives us fundamentally different building blocks. Let's use them.

## What JS Doesn't Have (That We Do)

| JS Problem | Elixir Solution |
|-----------|----------------|
| Single-threaded — loop must be async, callback-heavy | Each session is a process. Blocking is fine inside a process. |
| No built-in concurrency model — tool parallelism needs Promise.all | `Task.async_stream` / multiple `Task`s under a supervisor |
| State is a mutable object on a class | State is the GenServer state, immutable between messages |
| Events via callback sets, manually awaited | Process messages, Registry dispatch, Telemetry for observability |
| AbortSignal (cooperative cancellation) | Kill the Task, or send `:abort` to the GenServer |
| Queues for steering/follow-up (polled via callbacks) | Messages in the GenServer mailbox — checked between turns naturally |
| `convertToLlm` callback to strip custom messages | Pattern matching on message types — trivial |
| No supervision — crash = crash | Supervisor restarts the session process, state recoverable from persistence |

## The Key Shift: Process IS the Session

In pi-mono: `Agent` class + `agentLoop()` pure function + callbacks + AbortSignal + event listeners.

In PiEx: **one GenServer per session**. It holds:
- Messages (conversation history)
- Tools (available tools)
- Model config
- System prompt
- Subscribers (pids to notify)

The "loop" isn't a function that runs to completion. It's the GenServer's lifecycle:

```
                     ┌──────────────────────────────┐
                     │      PiEx.Agent (GenServer)   │
                     │                               │
  prompt(pid, text) ─┼─► handle_cast(:prompt, ...)   │
                     │     │                         │
                     │     ├─ spawn linked Task:     │
                     │     │   stream LLM response   │
                     │     │   send chunks back      │
                     │     │                         │
  steer(pid, text)  ─┼─► handle_cast(:steer, ...)   │
                     │     │ (queued in state)        │
                     │     │                         │
  {:llm_chunk, ...} ─┼─► handle_info                 │
                     │     │ broadcast to subscribers │
                     │     │                         │
  {:llm_done, msg}  ─┼─► handle_info                 │
                     │     │ extract tool_calls       │
                     │     │ execute tools            │
                     │     │ if tools ran → loop      │
                     │     │ if steering → loop       │
                     │     │ else → idle              │
                     │     │                         │
  abort(pid)        ─┼─► handle_cast(:abort, ...)    │
                     │     │ kill streaming Task      │
                     └─────┴─────────────────────────┘
```

### Why This Is Better

1. **The GenServer stays responsive during LLM streaming.** Steering, abort, status queries — all handled via the mailbox while the Task streams.
2. **No callback hell.** The Task sends messages back. The GenServer pattern-matches on them.
3. **Crash isolation.** If a tool crashes, the Task dies, the GenServer gets `{:DOWN, ...}`, handles it gracefully.
4. **Natural state machine.** The GenServer state can track `:idle | :streaming | :executing_tools` — and reject/queue operations accordingly.

### But Keep the Core Logic Testable

We still want a pure module for the turn logic:

```elixir
# PiEx.Turn — pure functions, no processes
defmodule PiEx.Turn do
  @doc "Given an LLM response, extract tool calls and execute them"
  def process_response(response, tools, hooks) do
    # returns {new_messages, events, next_action}
    # next_action: :continue | :idle | {:error, reason}
  end

  @doc "Build the LLM request from current state"  
  def build_request(messages, system_prompt, tools, convert_fn) do
    # returns the request map for req_llm
  end
end
```

The GenServer orchestrates. The pure functions do the logic. Tests hit the pure functions directly.

## Ash Resources — Why

Plain structs work. But Ash gives us:

1. **Validations on creation** — a message always has valid role, content, timestamp
2. **Actions as the API** — `Message.create_user!(text)` not `%Message{role: :user, content: ...}`
3. **Calculations** — token estimates, content summaries
4. **Changesets** — track what changed, why
5. **Future: data layer swap** — add `AshSqlite` later, get persistence + querying for free
6. **Domain boundaries** — `PiEx.Chat` domain groups Message, Session, ToolCall resources

### Resource Design

```
PiEx.Chat (Ash Domain)
├── PiEx.Chat.Message          # A message in the conversation
├── PiEx.Chat.Content          # Embedded: text, image, tool_call, thinking block
├── PiEx.Chat.ToolResult       # Embedded: result from tool execution
├── PiEx.Chat.Session          # Session metadata + config
└── PiEx.Chat.Turn             # A single LLM turn (assistant msg + tool results)

PiEx.Tooling (Ash Domain)
├── PiEx.Tooling.ToolDefinition  # Registered tool metadata (name, desc, params)
└── PiEx.Tooling.ToolCall        # Embedded: a specific invocation
```

### Message Resource (Embedded, No Data Layer)

```elixir
defmodule PiEx.Chat.Message do
  use Ash.Resource,
    domain: PiEx.Chat,
    data_layer: :embedded  # no persistence, just structured data

  attributes do
    uuid_v7_primary_key :id
    attribute :role, :atom, constraints: [one_of: [:user, :assistant, :tool_result, :system]]
    attribute :content, {:array, PiEx.Chat.Content}
    attribute :timestamp, :utc_datetime_usec, default: &DateTime.utc_now/0
    
    # Assistant-specific
    attribute :model, :string
    attribute :provider, :string
    attribute :stop_reason, :atom, constraints: [one_of: [:end_turn, :tool_use, :error, :aborted]]
    attribute :usage, :map  # %{input: n, output: n, ...}
    attribute :error_message, :string
  end

  actions do
    defaults [:read]
    
    create :user do
      accept [:content]
      change set_attribute(:role, :user)
      change set_attribute(:timestamp, &DateTime.utc_now/0)
    end

    create :assistant do
      accept [:content, :model, :provider, :stop_reason, :usage, :error_message]
      change set_attribute(:role, :assistant)
    end

    create :tool_result do
      accept [:content, :tool_call_id, :tool_name, :is_error]
      change set_attribute(:role, :tool_result)
    end
  end
end
```

### Content as Union Type (Embedded)

```elixir
defmodule PiEx.Chat.Content do
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :type, :atom, constraints: [one_of: [:text, :image, :tool_call, :thinking]]

    # Text content
    attribute :text, :string

    # Image content
    attribute :media_type, :string
    attribute :data, :string  # base64

    # Tool call content
    attribute :tool_call_id, :string
    attribute :tool_name, :string
    attribute :arguments, :map

    # Thinking content
    attribute :thinking, :string
  end
end
```

### Why Embedded Resources + No Data Layer First

- They act as **validated structs** — `Ash.Changeset` catches bad data at creation
- They serialize to maps naturally — perfect for JSONL persistence
- Adding `AshSqlite` later means: add data_layer config, generate migrations, done
- Ash's `calculate` and `aggregate` work on in-memory data too

## Process Architecture

```
PiEx.Application (Supervisor)
├── Registry (PiEx.SessionRegistry)        # name → pid lookup
├── DynamicSupervisor (PiEx.SessionSupervisor)  # supervises Agent GenServers
│   ├── PiEx.Agent (session_1)
│   │   └── Task (LLM streaming)          # linked, dies with parent
│   ├── PiEx.Agent (session_2)
│   │   └── Task.Supervisor child tasks   # tool execution
│   └── ...
└── PiEx.ToolRegistry (GenServer or ETS)   # global tool definitions
```

### Agent States

```
:idle          → accepts :prompt, :continue
:streaming     → accepts :steer, :abort, :status  (rejects :prompt)
:tool_exec     → accepts :steer, :abort, :status  (rejects :prompt)
```

Transitions:
```
:idle ──prompt──► :streaming ──response_done──► :tool_exec ──tools_done──► :streaming (loop)
                                                                        └──► :idle (no more tools)
:streaming ──abort──► :idle (kill task)
:streaming ──error──► :idle (task crashed)
```

## Event Delivery — Three Channels

1. **Process messages** (primary) — subscribers get `{:pi_ex, session_id, event}` in their mailbox. For direct consumers (TUI, test process, LiveView).

2. **Telemetry** (observability) — `[:pi_ex, :turn, :start]`, `[:pi_ex, :tool, :execute]` etc. For logging, metrics, tracing. Free and standard.

3. **Optional PubSub** (distributed) — if Phoenix.PubSub is available, broadcast events on `"pi_ex:session:#{id}"` topic. For multi-node or LiveView.

## Tool Behaviour

```elixir
defmodule PiEx.Tool do
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()  # JSON Schema-ish
  @callback execute(args :: map(), context :: map()) :: 
    {:ok, PiEx.Chat.ToolResult.t()} | {:error, String.t()}
end
```

Tools are modules, not data. The behaviour is the contract. Registration is just telling the Agent which modules to use.

Tool execution happens in **separate Tasks** under the Agent, so:
- Parallel execution is natural (spawn multiple Tasks)
- Crash in one tool doesn't kill the session
- Timeout via `Task.await/2`

## What Changes from the Original Plan

| Original Plan | Rethink |
|--------------|---------|
| `PiEx.AgentLoop` pure function | `PiEx.Turn` pure functions + `PiEx.Agent` GenServer orchestration |
| `PiEx.Message` — plain struct | `PiEx.Chat.Message` — Ash embedded resource |
| `PiEx.Event` — struct | `PiEx.Event` — still a struct (events are transient, not persisted) |
| `PiEx.Session.JSONL` — separate module | Persistence as an optional Ash data layer swap later |
| Registry-based PubSub only | Process messages + Telemetry + optional PubSub |
| `PiEx.Config` — layered merge | Ash's built-in config or Application env, revisit later |
| Tools as behaviour + struct | Tools as behaviour modules, definitions queryable via Ash |

## Testing Strategy (Revised)

### Level 1: Ash Resource Tests
```elixir
test "creates a valid user message" do
  msg = PiEx.Chat.Message.create_user!("hello")
  assert msg.role == :user
  assert hd(msg.content).text == "hello"
end
```

### Level 2: Turn Logic Tests (Pure Functions)
```elixir
test "extracts tool calls from assistant response" do
  response = build_assistant_response(tool_calls: [...])
  {messages, events, :continue} = PiEx.Turn.process_response(response, tools, hooks)
  assert length(messages) == 2  # tool results
end
```

### Level 3: Agent GenServer Tests
```elixir
test "full prompt → response cycle with fake LLM" do
  {:ok, pid} = PiEx.Agent.start_link(stream_fn: &fake_stream/3, tools: [...])
  PiEx.Agent.subscribe(pid)
  PiEx.Agent.prompt(pid, "hello")
  
  assert_receive {:pi_ex, _, %{type: :agent_start}}
  assert_receive {:pi_ex, _, %{type: :message_update, delta: "Hi!"}}
  assert_receive {:pi_ex, _, %{type: :agent_end}}
end
```

### Level 4: Tool Tests (Real Filesystem)
```elixir
test "read tool reads a file" do
  File.write!(tmp_path, "hello world")
  {:ok, result} = PiEx.Tools.Read.execute(%{path: tmp_path}, %{cwd: tmp_dir})
  assert hd(result.content).text =~ "hello world"
end
```

### Level 5: Integration (Real LLM, tagged)
```elixir
@tag :integration
test "agent answers a question using tools" do
  {:ok, pid} = PiEx.Agent.start_link(
    model: {:anthropic, "claude-sonnet-4-20250514"},
    tools: PiEx.Tools.coding_tools()
  )
  PiEx.Agent.prompt(pid, "What files are in #{tmp_dir}?")
  assert_receive {:pi_ex, _, %{type: :agent_end}}, 30_000
end
```

## Implementation Order

1. **Ash setup** — domain, embedded resources (Message, Content, ToolResult)
2. **Tool behaviour** — define contract, implement Read + Bash
3. **PiEx.Turn** — pure turn logic (build_request, process_response)
4. **PiEx.Agent** — GenServer with state machine
5. **PiEx.LLM** — req_llm adapter (stream_fn)
6. **Wire it up** — DynamicSupervisor, Registry, public API
