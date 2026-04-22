# Pi Session Persistence — Deep Dive

## JSONL Format

Sessions are stored as append-only JSONL files. Each line is a self-contained JSON object with a `type` field.

**File location**: `~/.pi/agent/sessions/--<encoded-cwd>--/<timestamp>_<uuid>.jsonl`

The cwd is encoded by replacing `/` with `-`, e.g. `--home-user-project--`.

### Header (first line)

```json
{"type":"session","version":3,"id":"019db5b7-ad24-765e-8db4-b907fdcebcb7","timestamp":"2024-12-03T14:00:00.000Z","cwd":"/home/user/project"}
```

Optional: `parentSession` (path to source session if forked).

The header has **no** `id`/`parentId` — it's metadata only, not part of the tree.

### Versions

- **v1**: Linear (legacy, auto-migrated)
- **v2**: Tree structure with `id`/`parentId`
- **v3**: Renamed `hookMessage` role to `custom`

All are auto-migrated to v3 on load.

## Tree Structure

Every entry (except header) has:

```typescript
interface SessionEntryBase {
  type: string;
  id: string;           // 8-char hex (from randomUUID().slice(0,8))
  parentId: string | null;  // null for first entry
  timestamp: string;    // ISO timestamp
}
```

The tree works like a git DAG:
- First entry: `parentId: null`
- Each subsequent entry points to its parent
- **Branching**: move the `leafId` pointer to an earlier entry; next append creates a child there
- **All entries are immutable** — branching never modifies/deletes existing entries

```
[user] ─── [assistant] ─── [user] ─── [assistant] ─┬─ [user msg] ← current leaf
                                                    │
                                                    └─ [branch_summary] ─── [user msg] ← alt branch
```

### Path-to-leaf (context building)

`buildSessionContext()` walks from `leafId` → root via `parentId` chain, collecting entries into an ordered path. This path is the "active branch" — all other branches are invisible to the LLM.

```typescript
// Walk from leaf to root
const path = [];
let current = leaf;
while (current) {
  path.unshift(current);
  current = current.parentId ? byId.get(current.parentId) : undefined;
}
```

## Entry Types

| Type | Purpose | In LLM Context? |
|------|---------|-----------------|
| `message` | User/assistant/toolResult messages | ✅ |
| `compaction` | Summary replacing older messages | ✅ (as compactionSummary) |
| `branch_summary` | Summary of abandoned branch | ✅ (as branchSummary) |
| `custom_message` | Extension-injected content | ✅ (as user message) |
| `custom` | Extension state persistence | ❌ |
| `model_change` | Model switch record | ❌ (but affects settings) |
| `thinking_level_change` | Thinking level change | ❌ (but affects settings) |
| `label` | User bookmark on an entry | ❌ |
| `session_info` | Display name for session | ❌ |

### Example entries

```json
{"type":"message","id":"a1b2c3d4","parentId":null,"timestamp":"2024-12-03T14:00:01.000Z","message":{"role":"user","content":"Hello","timestamp":1701612001000}}
{"type":"message","id":"b2c3d4e5","parentId":"a1b2c3d4","timestamp":"2024-12-03T14:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Hi!"}],"provider":"anthropic","model":"claude-sonnet-4-5","usage":{"input":100,"output":50,"cacheRead":0,"cacheWrite":0,"totalTokens":150,"cost":{"input":0.001,"output":0.001,"cacheRead":0,"cacheWrite":0,"total":0.002}},"stopReason":"stop","timestamp":1701612002000}}
{"type":"compaction","id":"f6g7h8i9","parentId":"e5f6g7h8","timestamp":"2024-12-03T14:10:00.000Z","summary":"User discussed X, Y, Z...","firstKeptEntryId":"c3d4e5f6","tokensBefore":50000}
{"type":"branch_summary","id":"g7h8i9j0","parentId":"a1b2c3d4","timestamp":"2024-12-03T14:15:00.000Z","fromId":"f6g7h8i9","summary":"Branch explored approach A..."}
{"type":"custom","id":"h8i9j0k1","parentId":"g7h8i9j0","timestamp":"2024-12-03T14:20:00.000Z","customType":"my-extension","data":{"count":42}}
{"type":"model_change","id":"d4e5f6g7","parentId":"c3d4e5f6","timestamp":"2024-12-03T14:05:00.000Z","provider":"openai","modelId":"gpt-4o"}
{"type":"label","id":"j0k1l2m3","parentId":"i9j0k1l2","timestamp":"2024-12-03T14:30:00.000Z","targetId":"a1b2c3d4","label":"checkpoint-1"}
{"type":"session_info","id":"k1l2m3n4","parentId":"j0k1l2m3","timestamp":"2024-12-03T14:35:00.000Z","name":"Refactor auth module"}
```

## Message Types (AgentMessage union)

```typescript
type AgentMessage =
  | UserMessage          // role: "user"
  | AssistantMessage     // role: "assistant" (with usage, provider, model, stopReason)
  | ToolResultMessage    // role: "toolResult"
  | BashExecutionMessage // role: "bashExecution" (command, output, exitCode)
  | CustomMessage        // role: "custom" (extension-injected, display flag)
  | BranchSummaryMessage // role: "branchSummary"
  | CompactionSummaryMessage // role: "compactionSummary"
```

These are the `message` field inside `SessionMessageEntry`. Note that `BranchSummaryMessage` and `CompactionSummaryMessage` are **not** stored as message entries — they're stored as top-level `branch_summary` and `compaction` entry types, then converted to messages during `buildSessionContext()`.

## Session Lifecycle

### Create
```typescript
SessionManager.create(cwd, sessionDir?)
```
- Generates UUIDv7 session ID
- Creates `<sessionDir>/<timestamp>_<uuid>.jsonl`
- Writes header line
- `leafId = null`

### Append
```typescript
session.appendMessage(message) // returns entry id
```
- Creates entry with `id = randomUUID().slice(0,8)`, `parentId = this.leafId`
- Adds to in-memory arrays and index
- Advances `leafId` to new entry
- `appendFileSync()` the JSON line

### Branch (tree navigation)
```typescript
session.branch(entryId)  // move leaf to earlier point
session.branchWithSummary(entryId, summary)  // + add branch_summary
```
- Simply sets `leafId = entryId`
- Next append creates a child of that entry → new branch

### Fork (new file from branch)
```typescript
session.createBranchedSession(leafId)
```
- Extracts root→leaf path from tree
- Writes to new JSONL file with fresh header

### Resume
```typescript
SessionManager.open(path)
SessionManager.continueRecent(cwd)
```
- Reads JSONL, parses all entries
- Auto-migrates v1/v2 → v3
- Builds `byId` map, computes `leafId` (last entry)
- `_buildIndex()` finds the "last" entry (no children → leaf candidate, picks the latest)

### List
```typescript
SessionManager.list(cwd)     // sessions for a directory
SessionManager.listAll()      // all sessions across all projects
```
- Scans `~/.pi/agent/sessions/<encoded-cwd>/` for `.jsonl` files
- Reads header + counts messages + extracts first user message text
- Returns `SessionInfo[]` sorted by modified date

## Compaction

### Trigger
Compaction fires when context tokens exceed `contextWindow - reserveTokens` (default reserve: 16384).

```typescript
shouldCompact(contextTokens, contextWindow, settings)
// settings: { enabled: true, reserveTokens: 16384, keepRecentTokens: 20000 }
```

Token estimation uses `chars / 4` heuristic, refined by actual `usage` from the last assistant response.

### Algorithm

1. **`prepareCompaction(pathEntries, settings)`**:
   - Find previous compaction entry (if any) to get `previousSummary`
   - Find cut point: walk backwards from newest, accumulate tokens until `keepRecentTokens` budget hit
   - Valid cut points: user, assistant, bashExecution, custom, branchSummary messages (never toolResult)
   - Handle split turns: if cutting mid-turn, track the turn prefix separately
   - Collect messages to summarize (everything before cut point)
   - Extract file operations (read/write/edit) from tool calls

2. **`compact(preparation, model, ...)`**:
   - Call LLM with serialized conversation + structured prompt
   - If split turn: generate both history summary and turn prefix summary in parallel
   - Append file operation lists (`<read-files>`, `<modified-files>`) to summary
   - If previous summary exists: use UPDATE prompt (merge new info into existing summary)

3. **Result stored as `CompactionEntry`**:
   ```json
   {"type":"compaction","id":"...","parentId":"...","summary":"## Goal\n...","firstKeptEntryId":"c3d4e5f6","tokensBefore":50000,"details":{"readFiles":["a.ts"],"modifiedFiles":["b.ts"]}}
   ```

### Context reconstruction with compaction

In `buildSessionContext()`:
1. Emit compaction summary as first message
2. Emit "kept" messages (from `firstKeptEntryId` up to compaction entry)
3. Emit messages after compaction

This means old messages are still in the JSONL file but excluded from context.

### Summarization prompts

Two modes:
- **Initial**: Structured checkpoint format (Goal, Constraints, Progress, Key Decisions, Next Steps, Critical Context)
- **Update** (when previous summary exists): Merge new information into existing summary, preserving all prior info

## Branch Summarization

When navigating away from a branch via `/tree`:

1. **`collectEntriesForBranchSummary(session, oldLeafId, targetId)`**: Walk from old leaf to common ancestor with target
2. **`prepareBranchEntries(entries, tokenBudget)`**: Walk newest→oldest collecting messages within token budget; extract file ops
3. **`generateBranchSummary(entries, options)`**: LLM call with structured prompt → summary prepended with "The user explored a different conversation branch..."
4. Result stored as `BranchSummaryEntry` attached as child of the common ancestor

## SessionManager API Summary

### Static factories
| Method | Description |
|--------|-------------|
| `create(cwd, sessionDir?)` | New session |
| `open(path, sessionDir?)` | Open existing JSONL |
| `continueRecent(cwd, sessionDir?)` | Resume latest or create new |
| `inMemory(cwd?)` | No file persistence |
| `forkFrom(sourcePath, targetCwd, sessionDir?)` | Fork from another project |
| `list(cwd, sessionDir?)` | List sessions for directory |
| `listAll()` | List all sessions |

### Instance — append (all return entry ID)
| Method | Entry Type |
|--------|-----------|
| `appendMessage(msg)` | `message` |
| `appendCompaction(summary, firstKeptEntryId, tokensBefore, details?, fromHook?)` | `compaction` |
| `appendCustomEntry(customType, data?)` | `custom` |
| `appendCustomMessageEntry(customType, content, display, details?)` | `custom_message` |
| `appendModelChange(provider, modelId)` | `model_change` |
| `appendThinkingLevelChange(level)` | `thinking_level_change` |
| `appendLabelChange(targetId, label)` | `label` |
| `appendSessionInfo(name)` | `session_info` |

### Instance — navigation
| Method | Description |
|--------|-------------|
| `branch(entryId)` | Move leaf to entry |
| `resetLeaf()` | Reset leaf to null |
| `branchWithSummary(entryId, summary, details?, fromHook?)` | Branch + add summary |
| `getLeafId()` / `getLeafEntry()` | Current position |
| `getBranch(fromId?)` | Path from entry to root |
| `getTree()` | Full tree as `SessionTreeNode[]` |
| `getChildren(parentId)` | Direct children |

### Instance — context
| Method | Description |
|--------|-------------|
| `buildSessionContext()` | Messages + thinkingLevel + model for LLM |
| `getEntries()` | All entries (shallow copy) |
| `getHeader()` | Session header |
| `getEntry(id)` | Entry by ID |
| `getLabel(id)` | Label for entry |
| `getSessionName()` | Display name |

## File Organization

```
~/.pi/agent/sessions/
  --home-user-project-a--/
    2024-12-03T14-00-00_019db5b7-ad24-765e-8db4-b907fdcebcb7.jsonl
    2024-12-04T10-30-00_019db5b8-xxxx-xxxx-xxxx-xxxxxxxxxxxx.jsonl
  --home-user-project-b--/
    ...
```

Sessions are **scoped by cwd** — each project directory gets its own folder under sessions.

## Key Patterns for Elixir Implementation

### JSONL vs SQLite/Ash

| Pi Pattern | Elixir Equivalent | Notes |
|------------|-------------------|-------|
| Append-only JSONL | SQLite with ordered inserts / Ash resource | JSONL is simple but hard to query. SQLite is better for Elixir. |
| `id`/`parentId` tree | Adjacency list in DB table | Standard pattern, works well with Ash/Ecto |
| `byId` Map for lookups | DB index on `id` column | Natural in SQL |
| `leafId` pointer | Stored in session record | Could be a field on the session table |
| `buildSessionContext()` | Recursive CTE or application code | Walk parent chain, apply compaction logic |
| File per session | Row per session + entries table | `sessions` and `session_entries` tables |

### Recommended Ash Schema

```elixir
# Session resource
defmodule Session do
  attributes do
    uuid_primary_key :id  # UUIDv7
    attribute :cwd, :string
    attribute :leaf_entry_id, :string  # current position
    attribute :version, :integer, default: 3
    attribute :parent_session_id, :uuid  # for forks
    attribute :name, :string  # display name
    timestamps()
  end
end

# SessionEntry resource (the tree)
defmodule SessionEntry do
  attributes do
    attribute :id, :string, primary_key?: true  # 8-char hex
    attribute :session_id, :uuid
    attribute :parent_entry_id, :string  # null for root
    attribute :type, :atom  # :message, :compaction, :branch_summary, etc.
    attribute :data, :map   # the entry payload (message, summary, etc.)
    attribute :timestamp, :utc_datetime_usec
  end
end
```

### Key behaviors to replicate
1. **Append-only**: Never update/delete entries, only append new ones
2. **Tree via parentId**: Branch by changing leaf pointer, not by copying data
3. **Context building**: Walk leaf→root, apply compaction, convert to message list
4. **Compaction**: LLM-generated summary replacing old messages in context (not in storage)
5. **Branch summary**: LLM summary of abandoned path injected at branch point
6. **Labels**: Separate entry type pointing to target entry (last-write-wins per target)
