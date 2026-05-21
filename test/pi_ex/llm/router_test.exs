defmodule PiEx.LLM.RouterTest do
  use ExUnit.Case, async: true

  test "normalizes direct config into a single ReqLLM route" do
    config = PiEx.LLM.Router.normalize_config!(model: "openai:gpt-4.1", api_key: "key")

    assert config.strategy == :fallback
    assert [%{backend: :req_llm, model: "openai:gpt-4.1", api_key: "key"}] = config.routes
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
end
