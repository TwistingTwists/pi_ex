defmodule PiEx.Extension.Loader do
  @moduledoc "Discovers and loads .exs extension files at runtime."

  @doc "Find all .exs files in the given directories."
  @spec discover([String.t()]) :: [String.t()]
  def discover(paths \\ default_paths()) do
    paths
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(fn dir ->
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".exs"))
      |> Enum.sort()
      |> Enum.map(&Path.join(dir, &1))
    end)
  end

  @doc "Compile an .exs file and return the module implementing PiEx.Extension."
  @spec load(String.t()) :: {:ok, module()} | {:error, term()}
  def load(path) do
    modules = Code.compile_file(path)

    case Enum.find(modules, fn {mod, _bytecode} -> implements_extension?(mod) end) do
      {mod, _bytecode} -> {:ok, mod}
      nil -> {:error, {:no_extension_module, path}}
    end
  rescue
    e -> {:error, {e, __STACKTRACE__}}
  end

  @doc "Load all files from discovered paths."
  @spec load_all([String.t()]) :: [{:ok, module()} | {:error, term()}]
  def load_all(paths \\ nil) do
    (paths || discover())
    |> Enum.map(&load/1)
  end

  defp default_paths do
    [
      Path.expand("~/.pi_ex/extensions"),
      Path.join(File.cwd!(), ".pi_ex/extensions")
    ]
  end

  defp implements_extension?(mod) do
    behaviours = mod.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
    PiEx.Extension in behaviours
  rescue
    _ -> false
  end
end
