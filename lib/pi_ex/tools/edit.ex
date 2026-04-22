defmodule PiEx.Tools.Edit do
  @moduledoc "Exact text replacement in files."
  @behaviour PiEx.Tool

  @impl true
  def name, do: "edit"

  @impl true
  def description, do: "Edit a file using exact text replacement."

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["path", "edits"],
      properties: %{
        path: %{type: "string", description: "Path to the file to edit"},
        edits: %{
          type: "array",
          description: "List of edits to apply",
          items: %{
            type: "object",
            required: ["old_text", "new_text"],
            properties: %{
              old_text: %{type: "string", description: "Exact text to find"},
              new_text: %{type: "string", description: "Replacement text"}
            }
          }
        }
      }
    }
  end

  @impl true
  def execute(args, context) do
    path = resolve_path(args["path"] || args[:path], context.cwd)
    edits = args["edits"] || args[:edits]

    case File.read(path) do
      {:ok, original} ->
        apply_edits(original, edits, path)

      {:error, reason} ->
        {:error, "Failed to read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp apply_edits(original, edits, path) do
    # Validate all edits against original content first
    with :ok <- validate_edits(original, edits) do
      result =
        Enum.reduce(edits, original, fn edit, content ->
          old_text = edit["old_text"] || edit[:old_text]
          new_text = edit["new_text"] || edit[:new_text]
          String.replace(content, old_text, new_text, global: false)
        end)

      File.write!(path, result)

      {:ok,
       [%{type: :text, text: "Successfully edited #{path} (#{length(edits)} edits applied)"}]}
    end
  end

  defp validate_edits(original, edits) do
    Enum.reduce_while(edits, :ok, fn edit, :ok ->
      old_text = edit["old_text"] || edit[:old_text]

      case count_occurrences(original, old_text) do
        0 ->
          {:halt, {:error, "old_text not found in file: #{String.slice(old_text, 0..50)}"}}

        1 ->
          {:cont, :ok}

        n ->
          {:halt,
           {:error,
            "old_text found #{n} times (must be unique): #{String.slice(old_text, 0..50)}"}}
      end
    end)
  end

  defp count_occurrences(string, pattern) do
    string
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
  end

  defp resolve_path(path, cwd) do
    if Path.type(path) == :absolute, do: path, else: Path.join(cwd, path)
  end
end
