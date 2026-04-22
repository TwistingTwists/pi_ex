# PiEx oneshot mode — like `claude -p`
# Usage: mix run scripts/oneshot.exs "create a file called hello.txt with hello from pi_ex"

prompt = System.argv() |> Enum.join(" ")

if prompt == "" do
  IO.puts("Usage: mix run scripts/oneshot.exs \"your prompt here\"")
  System.halt(1)
end

api_key = System.get_env("ANTHROPIC_API_KEY") || raise "Set ANTHROPIC_API_KEY"
model = System.get_env("PI_EX_MODEL") || PiEx.LLM.default_model()

stream_fn = PiEx.LLM.stream_fn(model: model, api_key: api_key)

{:ok, pid} = PiEx.Agent.start_session(
  stream_fn: stream_fn,
  tools: PiEx.Tools.coding_tools(),
  system_prompt: """
  You are a helpful coding assistant. Use tools to complete tasks.
  Available tools: read, write, edit, bash.
  Be concise. Execute tasks immediately without asking for confirmation.
  """
)

PiEx.Agent.subscribe(pid)
PiEx.Agent.prompt(pid, prompt)

defmodule Oneshot do
  def wait_for_done do
    receive do
      {:pi_ex_native, _sid, %{type: :message_delta, delta: delta}} ->
        IO.write(delta)
        wait_for_done()

      {:pi_ex_native, _sid, %{type: :tool_end, message: msg}} ->
        status = if msg.is_error, do: "ERROR", else: "OK"
        IO.puts("\n  [#{status}] #{msg.tool_name}: #{String.slice(msg.content || "", 0..120)}")
        wait_for_done()

      {:pi_ex_native, _sid, %{type: :message_end, message: msg}} when msg.role == :assistant ->
        if msg.tool_calls != [] do
          for tc <- msg.tool_calls do
            IO.puts("\n  → #{tc.name}(#{inspect(tc.arguments)})")
          end
        end
        wait_for_done()

      {:pi_ex_native, _sid, %{type: :agent_end}} ->
        IO.puts("")
        :done

      {:pi_ex_native, _sid, %{type: :error, reason: reason}} ->
        IO.puts("\nERROR: #{inspect(reason)}")
        wait_for_done()

      {:pi_ex_native, _sid, _event} ->
        wait_for_done()

    after
      120_000 ->
        IO.puts("\nTimeout after 120s")
    end
  end
end

Oneshot.wait_for_done()
