defmodule PiEx.Tools.WriteTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "writes a file", %{tmp_dir: tmp_dir} do
    assert {:ok, [%{type: :text, text: text}]} =
             PiEx.Tools.Write.execute(%{"path" => "out.txt", "content" => "hello"}, %{
               cwd: tmp_dir
             })

    assert text =~ "Successfully wrote 5 bytes"
    assert File.read!(Path.join(tmp_dir, "out.txt")) == "hello"
  end

  @tag :tmp_dir
  test "creates parent directories", %{tmp_dir: tmp_dir} do
    assert {:ok, _} =
             PiEx.Tools.Write.execute(%{"path" => "a/b/c.txt", "content" => "nested"}, %{
               cwd: tmp_dir
             })

    assert File.read!(Path.join(tmp_dir, "a/b/c.txt")) == "nested"
  end

  @tag :tmp_dir
  test "overwrites existing file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "f.txt")
    File.write!(path, "old")

    assert {:ok, _} =
             PiEx.Tools.Write.execute(%{"path" => "f.txt", "content" => "new"}, %{cwd: tmp_dir})

    assert File.read!(path) == "new"
  end
end
