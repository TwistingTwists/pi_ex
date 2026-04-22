defmodule PiEx.Context do
  @moduledoc "Discovers AGENTS.md context files by walking up from cwd."

  @doc """
  Discover context files by walking from cwd up to filesystem root.
  Checks for AGENTS.md then CLAUDE.md at each level (first match wins per directory).
  Returns list of %{path: String.t(), content: String.t()} in root-first order.
  """
  def discover(cwd) do
    cwd
    |> ancestors()
    |> Enum.flat_map(fn dir ->
      cond do
        File.regular?(Path.join(dir, "AGENTS.md")) ->
          path = Path.join(dir, "AGENTS.md")
          [%{path: path, content: File.read!(path)}]

        File.regular?(Path.join(dir, "CLAUDE.md")) ->
          path = Path.join(dir, "CLAUDE.md")
          [%{path: path, content: File.read!(path)}]

        true ->
          []
      end
    end)
  end

  defp ancestors(path) do
    path
    |> Path.expand()
    |> do_ancestors([])
  end

  defp do_ancestors("/", acc), do: ["/" | acc]
  defp do_ancestors(path, acc), do: do_ancestors(Path.dirname(path), [path | acc])
end
