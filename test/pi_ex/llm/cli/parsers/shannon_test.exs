defmodule PiEx.LLM.CLI.Parsers.ShannonTest do
  use ExUnit.Case, async: true

  alias PiEx.LLM.CLI.Parsers.Shannon

  test "parses Shannon assistant text and result metadata without duplicating content" do
    {:ok, state} = Shannon.init([])

    assistant =
      Jason.encode!(%{
        type: "assistant",
        message: %{role: "assistant", content: [%{type: "text", text: "hello"}]},
        session_id: "s_1"
      })

    result =
      Jason.encode!(%{
        type: "result",
        subtype: "success",
        result: "hello",
        usage: %{input_tokens: 10, output_tokens: 1},
        stop_reason: "end_turn"
      })

    assert {:ok, [content], state} = Shannon.parse_line(assistant, state, %{})
    assert content.type == :content
    assert content.text == "hello"

    assert {:ok, [meta], _state} = Shannon.parse_line(result, state, %{})
    assert meta.type == :meta
    assert meta.usage == %{"input_tokens" => 10, "output_tokens" => 1}
    assert meta.finish_reason == "end_turn"
  end

  test "emits result text when no assistant content was seen" do
    {:ok, state} = Shannon.init([])

    result = Jason.encode!(%{type: "result", subtype: "success", result: "hello"})

    assert {:ok, [content, meta], _state} = Shannon.parse_line(result, state, %{})
    assert content.type == :content
    assert content.text == "hello"
    assert meta.type == :meta
  end

  test "parses Claude tool_use content blocks" do
    {:ok, state} = Shannon.init([])

    line =
      Jason.encode!(%{
        type: "assistant",
        message: %{
          role: "assistant",
          content: [
            %{type: "tool_use", id: "toolu_1", name: "read", input: %{path: "mix.exs"}}
          ]
        }
      })

    assert {:ok, [event], _state} = Shannon.parse_line(line, state, %{})
    assert event.type == :tool_call
    assert event.tool_call_id == "toolu_1"
    assert event.tool_name == "read"
    assert event.arguments == %{"path" => "mix.exs"}
  end
end
