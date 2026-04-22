defmodule PiEx.Tools.ReadTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "reads a file", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "test.txt"), "hello world")

    assert {:ok, [%{type: :text, text: text}]} =
             PiEx.Tools.Read.execute(%{"path" => "test.txt"}, %{cwd: tmp_dir})

    assert text =~ "hello world"
  end

  @tag :tmp_dir
  test "reads with offset and limit", %{tmp_dir: tmp_dir} do
    content = Enum.map_join(1..10, "\n", &"line #{&1}")
    File.write!(Path.join(tmp_dir, "test.txt"), content)

    assert {:ok, [%{type: :text, text: text}]} =
             PiEx.Tools.Read.execute(%{"path" => "test.txt", "offset" => 3, "limit" => 2}, %{
               cwd: tmp_dir
             })

    assert text == "line 3\nline 4"
  end

  test "returns error for missing file" do
    assert {:error, msg} =
             PiEx.Tools.Read.execute(%{"path" => "/nonexistent/file.txt"}, %{cwd: "/tmp"})

    assert msg =~ "Failed to read"
  end

  @tag :tmp_dir
  test "truncates large files", %{tmp_dir: tmp_dir} do
    # Generate > 2000 lines
    content = Enum.map_join(1..2500, "\n", &"line #{&1}")
    File.write!(Path.join(tmp_dir, "big.txt"), content)

    assert {:ok, [%{type: :text, text: text}]} =
             PiEx.Tools.Read.execute(%{"path" => "big.txt"}, %{cwd: tmp_dir})

    assert text =~ "[Truncated. Use offset/limit for large files.]"
  end
end
