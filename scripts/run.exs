# PiEx v0 — Interactive Runner
# Usage: ANTHROPIC_API_KEY=sk-... mix run scripts/run.exs

IO.puts("""
╔══════════════════════════════════════╗
║           PiEx v0 Agent              ║
╚══════════════════════════════════════╝
""")

# Validate API key
api_key = System.get_env("ANTHROPIC_API_KEY")

unless api_key do
  IO.puts("❌ ANTHROPIC_API_KEY not set. Export it and try again.")
  System.halt(1)
end

IO.puts("🔑 API key: #{String.slice(api_key, 0..7)}...#{String.slice(api_key, -4..-1)}")

model = System.get_env("PI_EX_MODEL") || PiEx.LLM.default_model()
IO.puts("🤖 Model: #{model}")
IO.puts("📁 CWD: #{File.cwd!()}")
IO.puts("🔧 Tools: #{Enum.map_join(PiEx.Tools.coding_tools(), ", ", & &1.name())}")
IO.puts("")

# Build the real stream function
stream_fn = PiEx.LLM.stream_fn(model: model, api_key: api_key)

# Start a session
{:ok, pid} = PiEx.Agent.start_session(
  stream_fn: stream_fn,
  tools: PiEx.Tools.coding_tools(),
  system_prompt: """
  You are a helpful coding assistant. You help users by reading files, executing commands, editing code, and writing new files.

  Available tools: read, write, edit, bash

  Guidelines:
  - Use bash for file operations like ls, find, grep
  - Use read to examine file contents
  - Use edit for precise text replacements
  - Use write for new files or complete rewrites
  - Be concise
  """
)

PiEx.Agent.subscribe(pid)

IO.puts("✅ Session started. Type your prompt (or 'quit' to exit):\n")

# Simple REPL loop
defmodule Runner do
  def loop(pid) do
    prompt = IO.gets("you> ") |> String.trim()

    case prompt do
      "quit" ->
        IO.puts("\n👋 Bye!")

      "" ->
        loop(pid)

      _ ->
        PiEx.Agent.prompt(pid, prompt)
        collect_events(pid)
        IO.puts("")
        loop(pid)
    end
  end

  def collect_events(pid) do
    receive do
      {:pi_ex, _sid, %{type: :agent_start}} ->
        IO.write("\n🤖 ")
        collect_events(pid)

      {:pi_ex, _sid, %{type: :message_end, message: msg}} when msg.role == :assistant ->
        IO.puts(msg.content || "")

        if msg.tool_calls != [] do
          for tc <- msg.tool_calls do
            IO.puts("  🔧 Calling #{tc.name}(#{inspect(tc.arguments)})")
          end
        end

        collect_events(pid)

      {:pi_ex, _sid, %{type: :tool_end, message: msg}} ->
        status = if msg.is_error, do: "❌", else: "✅"
        # Truncate long tool output for display
        content = msg.content || ""
        display = if String.length(content) > 200, do: String.slice(content, 0..197) <> "...", else: content
        IO.puts("  #{status} #{msg.tool_name}: #{display}")
        collect_events(pid)

      {:pi_ex, _sid, %{type: :turn_start}} ->
        collect_events(pid)

      {:pi_ex, _sid, %{type: :turn_end}} ->
        collect_events(pid)

      {:pi_ex, _sid, %{type: :agent_end, messages: msgs}} ->
        user_count = Enum.count(msgs, &(&1.role == :user))
        asst_count = Enum.count(msgs, &(&1.role == :assistant))
        tool_count = Enum.count(msgs, &(&1.role == :tool_result))
        IO.puts("  📊 #{user_count} user, #{asst_count} assistant, #{tool_count} tool messages")

      {:pi_ex, _sid, %{type: :error, reason: reason}} ->
        IO.puts("  ❌ Error: #{inspect(reason)}")
        collect_events(pid)

      other ->
        # Catch any unexpected events
        IO.puts("  [event] #{inspect(other)}")
        collect_events(pid)
    after
      60_000 ->
        IO.puts("  ⏱️ Timeout waiting for response")
    end
  end
end

Runner.loop(pid)
