defmodule PiEx.Tools.Write do
  @moduledoc "Writes content to a file."
  @behaviour PiEx.Tool

  @impl true
  def name, do: "write"

  @impl true
  def description, do: "Write content to a file. Creates parent directories if needed."

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["path", "content"],
      properties: %{
        path: %{type: "string", description: "Path to the file to write"},
        content: %{type: "string", description: "Content to write to the file"}
      }
    }
  end

  @impl true
  def execute(args, context) do
    path = resolve_path(args["path"] || args[:path], context.cwd)
    content = args["content"] || args[:content]

    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, content)

    {:ok, [%{type: :text, text: "Successfully wrote #{byte_size(content)} bytes to #{path}"}]}
  rescue
    e -> {:error, "Failed to write #{args["path"] || args[:path]}: #{Exception.message(e)}"}
  end

  defp resolve_path(path, cwd) do
    if Path.type(path) == :absolute, do: path, else: Path.join(cwd, path)
  end
end
