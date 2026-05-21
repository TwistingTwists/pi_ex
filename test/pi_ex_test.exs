defmodule PiExTest do
  use ExUnit.Case
  doctest PiEx

  test "package includes orchestration example without packaging generated deps" do
    files = PiEx.MixProject.project()[:package][:files]

    assert "examples/orchestrator_demo/README.md" in files
    refute "examples" in files
  end
end
