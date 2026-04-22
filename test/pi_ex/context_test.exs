defmodule PiEx.ContextTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "discovers AGENTS.md walking up ancestors", %{tmp_dir: tmp_dir} do
    a = Path.join(tmp_dir, "a")
    b = Path.join(a, "b")
    c = Path.join(b, "c")
    File.mkdir_p!(c)

    File.write!(Path.join(tmp_dir, "AGENTS.md"), "root context")
    File.write!(Path.join(b, "AGENTS.md"), "mid context")

    results = PiEx.Context.discover(c)
    paths = Enum.map(results, & &1.path)

    root_idx = Enum.find_index(paths, &(&1 =~ "#{tmp_dir}/AGENTS.md"))
    mid_idx = Enum.find_index(paths, &(&1 =~ "#{b}/AGENTS.md"))

    assert root_idx != nil
    assert mid_idx != nil
    assert root_idx < mid_idx
  end

  @tag :tmp_dir
  test "returns empty when no context files exist", %{tmp_dir: tmp_dir} do
    results = PiEx.Context.discover(tmp_dir)
    tmp_results = Enum.filter(results, &String.starts_with?(&1.path, tmp_dir))
    assert tmp_results == []
  end
end
