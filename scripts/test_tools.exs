# Tests all 4 tools in one prompt via the agent loop.
# Usage: mix run scripts/test_tools.exs

api_key = System.get_env("ANTHROPIC_API_KEY") || raise "Set ANTHROPIC_API_KEY"
model = System.get_env("PI_EX_MODEL") || PiEx.LLM.default_model()
stream_fn = PiEx.LLM.stream_fn(model: model, api_key: api_key)
tmp = Path.join(System.tmp_dir!(), "pi_ex_test_#{System.unique_integer([:positive])}")
File.mkdir_p!(tmp)

# Seed a file for it to read
seed_file = Path.join(tmp, "mix.exs")
File.write!(seed_file, """
defmodule MyApp.MixProject do
  use Mix.Project

  def project do
    [app: :my_app, version: "0.1.0"]
  end

  defp deps do
    [{:jason, "~> 1.4"}, {:req, "~> 0.5"}]
  end
end
""")

IO.puts("═══ PiEx 4-Tool Integration Test ═══")
IO.puts("Model: #{model}")
IO.puts("Tmp dir: #{tmp}\n")

{:ok, pid} = PiEx.Agent.start_session(
  stream_fn: stream_fn,
  tools: PiEx.Tools.coding_tools(),
  cwd: tmp,
  system_prompt: "You are a coding assistant. Execute tasks immediately using tools. Be concise. Do not explain, just do it."
)

PiEx.Agent.subscribe(pid)

prompt = """
Do these steps in order:
1. Read the file mix.exs
2. Edit it: replace "0.1.0" with "0.2.0"
3. Write a new file called summary.txt with a one-line summary of what mix.exs contains
4. Run bash: wc -l mix.exs summary.txt

After all steps, report what each tool returned.
"""

IO.puts("Prompt:\n#{prompt}")
PiEx.Agent.prompt(pid, prompt)

defmodule Collector do
  def wait do
    receive do
      {:pi_ex, _sid, %{type: :message_delta, delta: d}} -> IO.write(d); wait()
      {:pi_ex, _sid, %{type: :tool_end, message: m}} ->
        s = if m.is_error, do: "❌", else: "✅"
        IO.puts("\n  #{s} #{m.tool_name}: #{String.slice(m.content || "", 0..120)}")
        wait()
      {:pi_ex, _sid, %{type: :message_end, message: m}} when m.role == :assistant ->
        for tc <- (m.tool_calls || []), do: IO.puts("\n  → #{tc.name}(#{inspect(tc.arguments)})")
        wait()
      {:pi_ex, _sid, %{type: :agent_end}} -> :ok
      {:pi_ex, _sid, %{type: :error, reason: r}} -> IO.puts("\n  ❌ ERROR: #{inspect(r)}"); wait()
      {:pi_ex, _sid, _} -> wait()
    after
      120_000 -> IO.puts("\n  ⏱️ Timeout")
    end
  end
end

Collector.wait()

# Verify results
IO.puts("\n\n═══ Verification ═══")

mix = File.read!(Path.join(tmp, "mix.exs"))
if mix =~ "0.2.0" and not (mix =~ "0.1.0") do
  IO.puts("✅ edit: version changed to 0.2.0")
else
  IO.puts("❌ edit: #{inspect(mix)}")
end

summary = Path.join(tmp, "summary.txt")
if File.exists?(summary) do
  IO.puts("✅ write: summary.txt exists — #{inspect(String.trim(File.read!(summary)))}")
else
  IO.puts("❌ write: summary.txt not created")
end

File.rm_rf!(tmp)
IO.puts("\nCleaned up #{tmp}")
