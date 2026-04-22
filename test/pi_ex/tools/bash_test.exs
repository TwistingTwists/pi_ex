defmodule PiEx.Tools.BashTest do
  use ExUnit.Case, async: true

  test "basic command" do
    assert {:ok, [%{type: :text, text: text}]} =
             PiEx.Tools.Bash.execute(%{"command" => "echo hello"}, %{cwd: "/tmp"})

    assert text =~ "hello"
  end

  test "timeout" do
    assert {:error, msg} =
             PiEx.Tools.Bash.execute(%{"command" => "sleep 10", "timeout" => 1}, %{cwd: "/tmp"})

    assert msg =~ "timed out"
  end

  test "exit code in output" do
    assert {:ok, [%{type: :text, text: text}]} =
             PiEx.Tools.Bash.execute(%{"command" => "exit 42"}, %{cwd: "/tmp"})

    assert text =~ "Exit code: 42"
  end
end
