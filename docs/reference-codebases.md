# Reference Codebases

## pi-mono (primary inspiration)

**What:** Minimal terminal coding agent harness by @badlogic. TypeScript, npm package.

**Local path:** `/home/abhishek/.local/share/mise/installs/npm-mariozechner-pi-coding-agent/0.68.1/lib/node_modules/@mariozechner/pi-coding-agent/`

**Key locations:**
- `dist/core/agent-session.js` — session lifecycle, event wiring
- `dist/core/system-prompt.js` — composable prompt builder
- `dist/core/settings-manager.js` — layered config (global → project → runtime)
- `dist/core/resource-loader.js` — skills, extensions, context file discovery
- `dist/core/session-manager.js` — JSONL tree persistence, branching
- `dist/core/compaction/` — context window management via LLM summarization
- `dist/core/extensions/` — extension loader, runner, API surface
- `dist/core/tools/` — read, write, edit, bash tool implementations
- `node_modules/@mariozechner/pi-agent-core/dist/` — core loop, Agent class, types
- `docs/` — sdk.md, extensions.md, skills.md, session.md, settings.md

**Patterns we adopted:** agent loop, 4 default tools, JSONL tree sessions, composable system prompt, before/after tool hooks, steering/follow-up queues, progressive skill disclosure.

## claude-elixir-phoenix (Elixir idiom reference)

**What:** Claude Code plugin for Elixir/Phoenix development. Agents, skills, hooks, iron laws.

**Local path:** `/home/abhishek/Downloads/experiments/ai-tools/marketplace_of_abeeshake/meta-repo/claude-elixir-phoenix/`

**Key locations:**
- `CLAUDE.md` — iron laws, idiomatic patterns, auto-loading rules, workflow routing
- `plugins/elixir-phoenix/agents/` — 20 specialist agents
- `plugins/elixir-phoenix/skills/` — 38 skills with references/
- `plugins/elixir-phoenix/hooks/hooks.json` — PreToolUse, PostToolUse, SubagentStart

**Patterns we adopted:** `@type`/`@spec` on public APIs, pipeline operators, pattern matching in function heads, `with` chains, extract helper functions, wrap third-party APIs, supervise all processes. Iron laws for reference (OTP #13/#14, Elixir #20).

## Our research docs

Detailed analysis of pi-mono's internals lives in `research/`:
- `research/system-prompt-and-config.md` — prompt structure, config layering, context discovery
- `research/hooks-and-interception.md` — tool pipeline, extension events, API surface
- `research/session-persistence.md` — JSONL format, tree structure, compaction, branching
