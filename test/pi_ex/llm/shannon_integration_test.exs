defmodule PiEx.LLM.ShannonIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :shannon
  @moduletag :integration
  @moduletag timeout: 240_000

  test "routes Shannon stream-json output through the CLI parser" do
    unless run_shannon_tests?() do
      IO.puts("Skipping Shannon integration test. Set RUN_SHANNON_TESTS=1 to run it.")
    else
      # Shannon currently derives its transcript folder differently from Claude Code
      # for paths containing underscores. Use a plain temp cwd so the integration
      # exercises Shannon itself instead of that path-normalization mismatch.
      shannon_cwd = "/tmp/shannon-piex"
      File.mkdir_p!(shannon_cwd)

      stream_fn =
        PiEx.LLM.Router.stream_fn(
          routes: [
            [
              name: :shannon,
              backend: :jsonl_cli,
              command: [
                "shannon",
                "-p",
                "Reply with exactly: hello",
                "--output-format=stream-json",
                "--verbose"
              ],
              parser: PiEx.LLM.CLI.Parsers.Shannon,
              stdin: :none,
              model: "shannon:claude-code",
              cwd: shannon_cwd,
              timeout: 220_000
            ]
          ]
        )

      assert {:ok, msg} = stream_fn.([], "", [], cwd: shannon_cwd)
      assert String.trim(msg.content) == "hello"
      assert msg.provider == "cli"
      assert msg.model == "shannon:claude-code"
    end
  end

  defp run_shannon_tests? do
    System.get_env("RUN_SHANNON_TESTS") == "1" && System.find_executable("shannon") != nil
  end
end
