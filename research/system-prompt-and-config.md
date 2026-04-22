# Pi System Prompt & Configuration Architecture

Research from pi-mono v0.68.1 codebase.

## 1. System Prompt Architecture

**File:** `dist/core/system-prompt.js` — `buildSystemPrompt(options)`

The system prompt is assembled from these sections in order:

### Structure (default prompt, no customPrompt)

```
1. Role preamble ("You are an expert coding assistant operating inside pi...")
2. Available tools (filtered list with one-line snippets)
3. Guidelines (tool-dependent + custom + universal)
4. Pi documentation references (paths to README, docs, examples)
5. appendSystemPrompt (from APPEND_SYSTEM.md or CLI)
6. Project Context (AGENTS.md / CLAUDE.md files)
7. Skills (XML format, only if `read` tool available)
8. Current date
9. Current working directory
```

### Structure (custom prompt via SYSTEM.md)

When `customPrompt` is set (from `.pi/SYSTEM.md` or `~/.pi/agent/SYSTEM.md`):

```
1. Custom prompt content (verbatim)
2. appendSystemPrompt
3. Project Context (AGENTS.md / CLAUDE.md files)
4. Skills (if read tool available)
5. Current date
6. Current working directory
```

### Key implementation details

```javascript
// Tools list: only tools with snippets appear
const visibleTools = tools.filter((name) => !!toolSnippets?.[name]);
const toolsList = visibleTools.map((name) => `- ${name}: ${toolSnippets[name]}`).join("\n");

// Date format: YYYY-MM-DD
const date = `${year}-${month}-${day}`;

// CWD uses forward slashes
const promptCwd = resolvedCwd.replace(/\\/g, "/");
```

## 2. Tool-Dependent Guidelines

Guidelines are built dynamically based on which tools are active. A `Set` deduplicates them.

```javascript
// If bash exists but no dedicated grep/find/ls tools:
"Use bash for file operations like ls, rg, find"

// If bash AND grep/find/ls exist:
"Prefer grep/find/ls tools over bash for file exploration (faster, respects .gitignore)"

// Then: all custom promptGuidelines from extensions/tools
// Always added last:
"Be concise in your responses"
"Show file paths clearly when working with files"
```

The `addGuideline` function uses a `Set` to prevent duplicates — important because multiple extensions may register the same guideline.

## 3. Config Layering (Settings)

**File:** `dist/core/settings-manager.js`

### Three-layer merge

```
global (~/.pi/agent/settings.json)
  ↓ deepMerge
project (.pi/settings.json)
  ↓ applyOverrides
runtime (CLI flags, programmatic overrides)
```

### Deep merge semantics

```javascript
function deepMergeSettings(base, overrides) {
    // Nested objects: merge recursively (one level deep — spread, not recursive)
    // Primitives and arrays: override wins completely
    // undefined values in overrides: skipped (don't clobber base)
}
```

**Important:** The merge is only one level deep for nested objects. `{ compaction: { enabled: false } }` in project will merge with global's `compaction` object, but arrays like `packages` are replaced entirely.

### Runtime overrides

```javascript
// Applied after global+project merge, not persisted
applyOverrides(overrides) {
    this.settings = deepMergeSettings(this.settings, overrides);
}
```

### Persistence

Settings are written with file locking (`proper-lockfile`). On save, only fields marked as "modified" are written — the manager reads the current file, merges modified fields, and writes back. This prevents clobbering changes made by other processes.

```javascript
// Track which fields were modified in-session
modifiedFields: Set<string>
modifiedNestedFields: Map<string, Set<string>>  // e.g., "compaction" -> {"enabled"}
```

### Migration

Old settings formats are auto-migrated:
- `queueMode` → `steeringMode`
- `websockets: boolean` → `transport: "websocket" | "sse"`
- `skills: { customDirectories, enableSkillCommands }` → `skills: string[]` + `enableSkillCommands`

## 4. Context File Discovery (AGENTS.md / CLAUDE.md)

**File:** `dist/core/resource-loader.js` — `loadProjectContextFiles()`

### Algorithm

```
1. Load from agentDir (~/.pi/agent/) — check AGENTS.md, then CLAUDE.md
2. Walk from cwd UP to filesystem root:
   - At each directory, check for AGENTS.md, then CLAUDE.md (first match wins)
   - Collect in array (will be reversed to root-first order)
3. Prepend global context, then ancestor files (root → cwd order)
4. Deduplicate by path
```

### Ordering in prompt

```
global (~/.pi/agent/AGENTS.md)
/home/user/AGENTS.md           (furthest ancestor)
/home/user/projects/AGENTS.md  (closer)
/home/user/projects/foo/AGENTS.md  (cwd)
```

Each appears as:
```markdown
# Project Context

Project-specific instructions and guidelines:

## /path/to/AGENTS.md

<content>
```

### Custom system prompt discovery

```
.pi/SYSTEM.md         (project, checked first)
~/.pi/agent/SYSTEM.md (global fallback)

.pi/APPEND_SYSTEM.md         (project, checked first)
~/.pi/agent/APPEND_SYSTEM.md (global fallback)
```

`SYSTEM.md` replaces the entire default prompt. `APPEND_SYSTEM.md` appends to whichever prompt is active.

## 5. Skills Integration

**File:** `dist/core/skills.js`

### Discovery locations (in order, first wins on name collision)

1. `~/.pi/agent/skills/` — user global (direct .md files + recursive SKILL.md)
2. `.pi/skills/` — project (direct .md files + recursive SKILL.md)
3. `~/.agents/skills/` — cross-harness global (SKILL.md only, no root .md)
4. `.agents/skills/` in ancestors — cross-harness project (SKILL.md only)
5. Package `skills/` directories
6. Settings `skills` array paths
7. CLI `--skill` paths

### SKILL.md format

Frontmatter with `name` and `description`. Name validated: lowercase, hyphens, max 64 chars, must match parent dir name. Description required, max 1024 chars.

### System prompt format (XML)

```xml
The following skills provide specialized instructions for specific tasks.
Use the read tool to load a skill's file when the task matches its description.
When a skill file references a relative path, resolve it against the skill directory...

<available_skills>
  <skill>
    <name>skill-name</name>
    <description>What it does</description>
    <location>/absolute/path/to/SKILL.md</location>
  </skill>
</available_skills>
```

**Progressive disclosure:** Only name + description in system prompt. Full content loaded on-demand via `read` tool. Skills with `disable-model-invocation: true` in frontmatter are excluded from the prompt (command-only).

Skills section only included if the `read` tool is available (otherwise the model couldn't load them).

### Collision handling

First skill with a given name wins. Collisions produce diagnostic warnings with winner/loser paths.

### Ignore files respected

`.gitignore`, `.ignore`, `.fdignore` patterns are respected during skill directory scanning.

## 6. Config Value Resolution

**File:** `dist/core/resolve-config-value.js`

Three resolution modes for any config value (API keys, headers, etc.):

```
"!command"     → Execute shell command, use stdout (cached for process lifetime)
"ENV_VAR_NAME" → Check process.env[value], return if set
"literal"      → Return as-is (fallback)
```

```javascript
// Shell command results are cached globally
const commandResultCache = new Map();

// Resolution: ! prefix = command, else try env var, else literal
export function resolveConfigValue(config) {
    if (config.startsWith("!")) return executeCommand(config);
    return process.env[config] || config;
}
```

Shell commands have a 10-second timeout. On Windows, tries configured shell first, then falls back to `execSync`.

## 7. Complete Settings Schema

| Setting | Type | Default |
|---------|------|---------|
| `defaultProvider` | string | - |
| `defaultModel` | string | - |
| `defaultThinkingLevel` | `"off"\|"minimal"\|"low"\|"medium"\|"high"\|"xhigh"` | - |
| `hideThinkingBlock` | boolean | `false` |
| `thinkingBudgets` | `{level: number}` | - |
| `theme` | string | `"dark"` |
| `quietStartup` | boolean | `false` |
| `collapseChangelog` | boolean | `false` |
| `enableInstallTelemetry` | boolean | `true` |
| `doubleEscapeAction` | `"tree"\|"fork"\|"none"` | `"tree"` |
| `treeFilterMode` | string | `"default"` |
| `editorPaddingX` | number | `0` |
| `autocompleteMaxVisible` | number | `5` |
| `showHardwareCursor` | boolean | `false` |
| `compaction.enabled` | boolean | `true` |
| `compaction.reserveTokens` | number | `16384` |
| `compaction.keepRecentTokens` | number | `20000` |
| `branchSummary.reserveTokens` | number | `16384` |
| `branchSummary.skipPrompt` | boolean | `false` |
| `retry.enabled` | boolean | `true` |
| `retry.maxRetries` | number | `3` |
| `retry.baseDelayMs` | number | `2000` |
| `retry.maxDelayMs` | number | `60000` |
| `steeringMode` | `"all"\|"one-at-a-time"` | `"one-at-a-time"` |
| `followUpMode` | `"all"\|"one-at-a-time"` | `"one-at-a-time"` |
| `transport` | `"sse"\|"websocket"\|"auto"` | `"sse"` |
| `terminal.showImages` | boolean | `true` |
| `terminal.imageWidthCells` | number | `60` |
| `terminal.clearOnShrink` | boolean | `false` |
| `images.autoResize` | boolean | `true` |
| `images.blockImages` | boolean | `false` |
| `shellPath` | string | - |
| `shellCommandPrefix` | string | - |
| `npmCommand` | string[] | - |
| `sessionDir` | string | - |
| `enabledModels` | string[] | - |
| `markdown.codeBlockIndent` | string | `"  "` |
| `packages` | array | `[]` |
| `extensions` | string[] | `[]` |
| `skills` | string[] | `[]` |
| `prompts` | string[] | `[]` |
| `themes` | string[] | `[]` |
| `enableSkillCommands` | boolean | `true` |
| `lastChangelogVersion` | string | - |

## 8. Key Patterns for Elixir Replication

### Pattern: Progressive disclosure via XML
Skills use a catalog (name + description + path) in the system prompt. Full content is loaded on-demand. This keeps the prompt small while making capabilities discoverable.

### Pattern: Tool-aware prompt construction
The system prompt adapts to available tools. Guidelines change based on which tools exist. Skills section is omitted if `read` isn't available.

### Pattern: Layered config with dirty tracking
Settings use global → project → runtime layering with `deepMerge`. Only modified fields are persisted (dirty tracking via `Set<string>`), preventing concurrent write conflicts.

### Pattern: Ancestor directory walking for context
Context files are discovered by walking from cwd to root, collecting AGENTS.md/CLAUDE.md at each level. Order is root-first (outermost context first, project-specific last).

### Pattern: Config value resolution with shell commands
API keys and headers can be shell commands (`!op read ...`), env var names, or literals. Shell results are cached for process lifetime.

### Pattern: Deduplication by name with collision diagnostics
Skills, prompts, and themes use first-wins deduplication with diagnostic warnings for collisions, not errors.

### Pattern: Custom vs default system prompt
SYSTEM.md completely replaces the default prompt. APPEND_SYSTEM.md adds to either. Both support project and global scopes with project taking precedence.
