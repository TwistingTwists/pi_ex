defmodule PiEx.Tools.EditTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "single edit", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "f.txt")
    File.write!(path, "hello world")

    assert {:ok, [%{type: :text, text: text}]} =
             PiEx.Tools.Edit.execute(
               %{
                 "path" => "f.txt",
                 "edits" => [%{"old_text" => "hello", "new_text" => "goodbye"}]
               },
               %{cwd: tmp_dir}
             )

    assert text =~ "1 edits applied"
    assert File.read!(path) == "goodbye world"
  end

  @tag :tmp_dir
  test "multiple edits", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "f.txt")
    File.write!(path, "aaa bbb ccc")

    assert {:ok, _} =
             PiEx.Tools.Edit.execute(
               %{
                 "path" => "f.txt",
                 "edits" => [
                   %{"old_text" => "aaa", "new_text" => "xxx"},
                   %{"old_text" => "ccc", "new_text" => "zzz"}
                 ]
               },
               %{cwd: tmp_dir}
             )

    assert File.read!(path) == "xxx bbb zzz"
  end

  @tag :tmp_dir
  test "old_text not found", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "f.txt"), "hello")

    assert {:error, msg} =
             PiEx.Tools.Edit.execute(
               %{"path" => "f.txt", "edits" => [%{"old_text" => "missing", "new_text" => "x"}]},
               %{cwd: tmp_dir}
             )

    assert msg =~ "not found"
  end

  @tag :tmp_dir
  test "old_text not unique", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "f.txt"), "aaa aaa bbb")

    assert {:error, msg} =
             PiEx.Tools.Edit.execute(
               %{"path" => "f.txt", "edits" => [%{"old_text" => "aaa", "new_text" => "x"}]},
               %{cwd: tmp_dir}
             )

    assert msg =~ "2 times"
  end
end
