defmodule PiEx.Tools.Read do
  @moduledoc "Reads file contents."
  @behaviour PiEx.Tool

  @max_lines 2000
  @max_bytes 50_000

  @impl true
  def name, do: "read"

  @impl true
  def description, do: "Read the contents of a file."

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["path"],
      properties: %{
        path: %{type: "string", description: "Path to the file to read"},
        offset: %{type: "integer", description: "Line number to start from (1-indexed)"},
        limit: %{type: "integer", description: "Max lines to read"}
      }
    }
  end

  @impl true
  def execute(args, context) do
    path = resolve_path(args["path"] || args[:path], context.cwd)
    offset = args["offset"] || args[:offset]
    limit = args["limit"] || args[:limit]

    case File.read(path) do
      {:ok, content} ->
        lines = String.split(content, "\n")

        lines =
          if offset do
            Enum.drop(lines, max(offset - 1, 0))
          else
            lines
          end

        lines =
          if limit do
            Enum.take(lines, limit)
          else
            lines
          end

        {lines, truncated} = truncate(lines)
        text = Enum.join(lines, "\n")

        text =
          if truncated do
            text <> "\n[Truncated. Use offset/limit for large files.]"
          else
            text
          end

        {:ok, [%{type: :text, text: text}]}

      {:error, reason} ->
        {:error, "Failed to read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp resolve_path(path, cwd) do
    if Path.type(path) == :absolute, do: path, else: Path.join(cwd, path)
  end

  defp truncate(lines) do
    {taken, _, truncated} =
      Enum.reduce_while(lines, {[], 0, false}, fn line, {acc, bytes, _} ->
        new_bytes = bytes + byte_size(line) + 1
        new_count = length(acc) + 1

        if new_count > @max_lines or new_bytes > @max_bytes do
          {:halt, {acc, bytes, true}}
        else
          {:cont, {acc ++ [line], new_bytes, false}}
        end
      end)

    {taken, truncated}
  end
end
