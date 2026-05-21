defmodule PiEx.LLM.RouterTest do
  use ExUnit.Case, async: true

  test "normalizes direct config into a single ReqLLM route" do
    config = PiEx.LLM.Router.normalize_config!(model: "openai:gpt-4.1", api_key: "key")

    assert config.strategy == :fallback
    assert [%{backend: :req_llm, model: "openai:gpt-4.1", api_key: "key"}] = config.routes
  end

  test "normalizes native ShannonEx routes" do
    config =
      PiEx.LLM.Router.normalize_config!(
        routes: [[name: :native_shannon, backend: :shannon_ex, model: "shannon:claude"]]
      )

    assert [%{backend: :shannon_ex, model: "shannon:claude"}] = config.routes
  end

  test "native ShannonEx route reports missing optional dependency" do
    stream_fn =
      PiEx.LLM.Router.stream_fn(
        routes: [[name: :native_shannon, backend: :shannon_ex, model: "shannon:claude"]]
      )

    assert {:error, reason} = stream_fn.([], "system", [], [])
    assert reason =~ "ShannonEx is not available"
  end

  @tag :tmp_dir
  test "streams from a native ShannonEx route", %{tmp_dir: tmp_dir} do
    runner = fn prompt, opts ->
      send(self(), {:shannon_prompt, prompt})
      send(self(), {:shannon_opts, opts})

      {:ok,
       [
         %{
           "type" => "assistant",
           "message" => %{
             "role" => "assistant",
             "content" => [%{"type" => "text", "text" => "native hello"}]
           }
         },
         %{
           "type" => "result",
           "subtype" => "success",
           "result" => "native hello",
           "usage" => %{"input_tokens" => 3, "output_tokens" => 2},
           "stop_reason" => "end_turn"
         }
       ]}
    end

    user_message =
      PiEx.Chat.Message
      |> Ash.Changeset.for_create(:create_user, %{content: "Reply natively"})
      |> Ash.create!()

    stream_fn =
      PiEx.LLM.Router.stream_fn(
        routes: [
          [
            name: :native_shannon,
            backend: :shannon_ex,
            model: "shannon:claude-code",
            cwd: tmp_dir,
            options: [runner: runner, claude_args: ["--model", "claude-sonnet-4"]]
          ]
        ]
      )

    assert {:ok, msg} = stream_fn.([user_message], "system prompt", [], cwd: tmp_dir)
    assert msg.content == "native hello"
    assert msg.provider == "shannon_ex"
    assert msg.model == "shannon:claude-code"
    assert msg.usage == %{"input_tokens" => 3, "output_tokens" => 2}
    assert msg.stop_reason == :end_turn

    assert_received {:shannon_prompt, prompt}
    assert prompt =~ "system prompt"
    assert prompt =~ "User: Reply natively"

    assert_received {:shannon_opts, opts}
    assert Keyword.fetch!(opts, :cwd) == tmp_dir
    assert Keyword.fetch!(opts, :runner) == runner
    assert Keyword.fetch!(opts, :claude_args) == ["--model", "claude-sonnet-4"]
  end

  @tag :tmp_dir
  @tag :shannon_ex
  @tag :integration
  @tag timeout: 240_000
  test "routes through the real native ShannonEx runner", %{tmp_dir: _tmp_dir} do
    unless run_shannon_ex_tests?() do
      IO.puts("Skipping native ShannonEx router test. Set RUN_SHANNON_EX_TESTS=1 to run it.")
    else
      shannon_cwd = "/tmp/shannon-piex-native"
      File.mkdir_p!(shannon_cwd)

      user_message =
        PiEx.Chat.Message
        |> Ash.Changeset.for_create(:create_user, %{content: "Reply with exactly: hello"})
        |> Ash.create!()

      stream_fn =
        PiEx.LLM.Router.stream_fn(
          routes: [
            [
              name: :native_shannon,
              backend: :shannon_ex,
              model: "shannon_ex:claude-code",
              cwd: shannon_cwd,
              options: [turn_timeout_ms: 220_000]
            ]
          ]
        )

      assert {:ok, msg} = stream_fn.([user_message], "", [], cwd: shannon_cwd)
      assert String.trim(msg.content) == "hello"
      assert msg.provider == "shannon_ex"
      assert msg.model == "shannon_ex:claude-code"
    end
  end

  @tag :tmp_dir
  test "streams from a CLI JSONL route", %{tmp_dir: tmp_dir} do
    script = Path.join(tmp_dir, "llm.sh")

    File.write!(script, """
    #!/bin/sh
    read _request
    printf '%s\n' '{"type":"content","text":"hello "}'
    printf '%s\n' '{"type":"content","text":"world"}'
    printf '%s\n' '{"type":"done"}'
    """)

    File.chmod!(script, 0o755)

    stream_fn =
      PiEx.LLM.Router.stream_fn(
        routes: [[name: :cli, backend: :jsonl_cli, command: [script], model: "cli:test"]]
      )

    assert {:ok, msg} = stream_fn.([], "system", [], cwd: tmp_dir)
    assert msg.content == "hello world"
    assert msg.model == "cli:test"
    assert msg.provider == "cli"
    assert msg.stop_reason == :end_turn
  end

  @tag :tmp_dir
  test "streams from a CLI route with a custom Shannon parser", %{tmp_dir: tmp_dir} do
    script = Path.join(tmp_dir, "shannon_fixture.sh")

    File.write!(script, """
    #!/bin/sh
    printf '%s\n' '{"type":"system","subtype":"init","session_id":"s_1"}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hello"}]}}'
    printf '%s\n' '{"type":"result","subtype":"success","result":"hello","usage":{"input_tokens":10,"output_tokens":1},"stop_reason":"end_turn"}'
    """)

    File.chmod!(script, 0o755)

    stream_fn =
      PiEx.LLM.Router.stream_fn(
        routes: [
          [
            name: :shannon,
            backend: :jsonl_cli,
            command: [script],
            parser: PiEx.LLM.CLI.Parsers.Shannon,
            stdin: :none,
            model: "shannon:test"
          ]
        ]
      )

    assert {:ok, msg} = stream_fn.([], "system", [], cwd: tmp_dir)
    assert msg.content == "hello"
    assert msg.usage == %{"input_tokens" => 10, "output_tokens" => 1}
    assert msg.stop_reason == :end_turn
  end

  @tag :tmp_dir
  test "normalizes CLI JSONL tool calls", %{tmp_dir: tmp_dir} do
    script = Path.join(tmp_dir, "llm_tool.sh")

    File.write!(script, """
    #!/bin/sh
    read _request
    printf '%s\n' '{"type":"tool_call","id":"call_1","name":"read","arguments":{"path":"mix.exs"}}'
    printf '%s\n' '{"type":"meta","finish_reason":"tool_calls"}'
    printf '%s\n' '{"type":"done"}'
    """)

    File.chmod!(script, 0o755)

    stream_fn =
      PiEx.LLM.Router.stream_fn(
        routes: [[name: :cli, backend: :jsonl_cli, command: [script], model: "cli:test"]]
      )

    assert {:ok, msg} = stream_fn.([], "system", [], cwd: tmp_dir)
    assert msg.stop_reason == :tool_use
    assert [%{id: "call_1", name: "read", arguments: %{"path" => "mix.exs"}}] = msg.tool_calls
  end

  defp run_shannon_ex_tests? do
    System.get_env("RUN_SHANNON_EX_TESTS") == "1" &&
      System.find_executable("claude") != nil &&
      System.find_executable("tmux") != nil
  end
end
