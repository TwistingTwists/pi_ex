defmodule PiEx.LLM.CLI.Parsers.Shannon do
  @moduledoc """
  Parser for Shannon's `--output-format=stream-json --verbose` output.

  Shannon emits Claude-Code-SDK-like JSON records. The useful records for PiEx
  are:

    * `type: "assistant"` — final assistant message for the turn
    * `type: "result"` — usage, stop reason, and sometimes final text
    * `type: "shannon_session"` — session metadata after cleanup

  This parser turns assistant text blocks into `:content` events and Claude
  `tool_use` content blocks into `:tool_call` events. Result records become
  `:meta` events; if Shannon returns a result without an assistant text record,
  the result text is emitted as content once.
  """

  @behaviour PiEx.LLM.CLI.Parser

  alias PiEx.LLM.CLI.Event

  @impl true
  def init(_opts), do: {:ok, %{emitted_content?: false}}

  @impl true
  def parse_line(line, state, _context) do
    line = String.trim(line)

    if line == "" do
      {:ok, [], state}
    else
      case Jason.decode(line) do
        {:ok, map} ->
          parse_record(map, state)

        {:error, %Jason.DecodeError{} = reason} ->
          {:error, "invalid Shannon JSON line #{inspect(line)}: #{Exception.message(reason)}"}
      end
    end
  end

  defp parse_record(%{"type" => "assistant", "message" => %{"content" => content}} = raw, state) do
    events = content_events(content, raw)
    emitted? = Enum.any?(events, &(&1.type == :content and present?(&1.text)))
    {:ok, events, %{state | emitted_content?: state.emitted_content? || emitted?}}
  end

  defp parse_record(%{"type" => "result"} = raw, state) do
    {content_events, state} = maybe_result_content(raw, state)

    meta =
      Event.new!(
        type: :meta,
        usage: raw["usage"] || raw["modelUsage"],
        finish_reason: finish_reason(raw),
        metadata: Map.drop(raw, ["type", "result", "usage", "modelUsage", "stop_reason"]),
        raw: raw
      )

    {:ok, content_events ++ [meta], state}
  end

  defp parse_record(%{"type" => "system"} = raw, state) do
    {:ok, [Event.new!(type: :meta, metadata: raw, raw: raw)], state}
  end

  defp parse_record(%{"type" => "shannon_session"} = raw, state) do
    {:ok, [Event.new!(type: :meta, metadata: raw, raw: raw)], state}
  end

  defp parse_record(%{"type" => "error"} = raw, state) do
    {:ok,
     [
       Event.new!(type: :error, message: raw["message"] || raw["error"] || inspect(raw), raw: raw)
     ], state}
  end

  defp parse_record(raw, state) when is_map(raw) do
    {:ok, [Event.new!(type: :ignore, raw: raw)], state}
  end

  defp maybe_result_content(%{"result" => text} = raw, %{emitted_content?: false} = state)
       when is_binary(text) do
    {[Event.new!(type: :content, text: text, raw: raw)], %{state | emitted_content?: text != ""}}
  end

  defp maybe_result_content(_raw, state), do: {[], state}

  defp content_events(content, raw) when is_binary(content) do
    if content == "", do: [], else: [Event.new!(type: :content, text: content, raw: raw)]
  end

  defp content_events(content, raw) when is_list(content) do
    Enum.flat_map(content, &content_block_event(&1, raw))
  end

  defp content_events(_content, _raw), do: []

  defp content_block_event(%{"type" => "text", "text" => text}, raw) when is_binary(text) do
    [Event.new!(type: :content, text: text, raw: raw)]
  end

  defp content_block_event(%{"type" => "thinking", "text" => text}, raw) when is_binary(text) do
    [Event.new!(type: :thinking, text: text, raw: raw)]
  end

  defp content_block_event(%{"type" => "tool_use"} = block, raw) do
    [
      Event.new!(
        type: :tool_call,
        tool_call_id: block["id"],
        tool_name: block["name"],
        arguments: block["input"] || %{},
        raw: raw
      )
    ]
  end

  defp content_block_event(_block, _raw), do: []

  defp finish_reason(%{"stop_reason" => reason}) when not is_nil(reason), do: to_string(reason)

  defp finish_reason(%{"terminal_reason" => reason}) when not is_nil(reason),
    do: to_string(reason)

  defp finish_reason(%{"subtype" => "success"}), do: "end_turn"
  defp finish_reason(_), do: nil

  defp present?(value), do: is_binary(value) and value != ""
end
