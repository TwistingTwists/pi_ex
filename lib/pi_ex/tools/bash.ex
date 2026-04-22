defmodule PiEx.Tools.Bash do
  @moduledoc "Execute shell commands."
  @behaviour PiEx.Tool

  @max_lines 2000
  @max_bytes 50_000
  @default_timeout 30

  @impl true
  def name, do: "bash"

  @impl true
  def description, do: "Execute a bash command and return stdout/stderr."

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["command"],
      properties: %{
        command: %{type: "string", description: "Bash command to execute"},
        timeout: %{type: "integer", description: "Timeout in seconds (default 30)"}
      }
    }
  end

  @impl true
  def execute(args, context) do
    command = args["command"] || args[:command]
    timeout = (args["timeout"] || args[:timeout] || @default_timeout) * 1000

    task =
      Task.async(fn ->
        System.cmd("bash", ["-c", command],
          cd: context.cwd,
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, exit_code}} ->
        {text, truncated} = truncate_output(output)

        text =
          if truncated do
            "[Output truncated. Showing last #{@max_lines} lines.]\n" <> text
          else
            text
          end

        text =
          if exit_code != 0 do
            text <> "\n[Exit code: #{exit_code}]"
          else
            text
          end

        {:ok, [%{type: :text, text: text}]}

      nil ->
        {:error, "Command timed out after #{div(timeout, 1000)} seconds"}
    end
  end

  defp truncate_output(output) do
    lines = String.split(output, "\n")
    total_lines = length(lines)
    total_bytes = byte_size(output)

    if total_lines <= @max_lines and total_bytes <= @max_bytes do
      {output, false}
    else
      # Take last @max_lines lines, then trim to @max_bytes
      taken = Enum.take(lines, -@max_lines)
      text = Enum.join(taken, "\n")

      text =
        if byte_size(text) > @max_bytes do
          binary_part(text, byte_size(text) - @max_bytes, @max_bytes)
        else
          text
        end

      {text, true}
    end
  end
end
