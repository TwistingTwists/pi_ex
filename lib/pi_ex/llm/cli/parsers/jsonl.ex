defmodule PiEx.LLM.CLI.Parsers.JSONL do
  @moduledoc """
  Default parser for PiEx's canonical CLI JSONL protocol.

  Accepted line shapes include:

      {"type":"content", "text":"hello"}
      {"type":"message_delta", "delta":"hello"}
      {"type":"thinking", "text":"reasoning"}
      {"type":"tool_call", "id":"call_1", "name":"read", "arguments":{"path":"mix.exs"}}
      {"type":"tool_call_delta", "index":0, "id":"call_1", "name":"read", "arguments_delta":"{..."}
      {"type":"meta", "finish_reason":"tool_calls", "usage":{}}
      {"type":"done"}
      {"type":"error", "message":"..."}
  """

  @behaviour PiEx.LLM.CLI.Parser

  alias PiEx.LLM.CLI.Event

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def parse_line(line, state, _context) do
    line = String.trim(line)

    cond do
      line == "" ->
        {:ok, [], state}

      true ->
        with {:ok, map} <- Jason.decode(line),
             {:ok, event} <- to_event(map) do
          {:ok, [event], state}
        else
          {:error, %Jason.DecodeError{} = reason} ->
            {:error, "invalid CLI JSONL line #{inspect(line)}: #{Exception.message(reason)}"}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp to_event(%{"type" => type} = map), do: build(type, map)
  defp to_event(%{type: type} = map), do: build(type, map)
  defp to_event(_), do: {:error, "CLI JSONL event is missing type"}

  defp build(type, map) when type in ["content", :content] do
    {:ok, Event.new!(type: :content, text: value(map, :text), raw: map)}
  end

  defp build(type, map) when type in ["message_delta", :message_delta] do
    {:ok, Event.new!(type: :content, text: value(map, :delta) || value(map, :text), raw: map)}
  end

  defp build(type, map) when type in ["thinking", :thinking] do
    {:ok, Event.new!(type: :thinking, text: value(map, :text) || value(map, :delta), raw: map)}
  end

  defp build(type, map) when type in ["tool_call", :tool_call] do
    {:ok,
     Event.new!(
       type: :tool_call,
       tool_call_id: value(map, :id),
       tool_name: value(map, :name),
       arguments: value(map, :arguments) || %{},
       raw: map
     )}
  end

  defp build(type, map) when type in ["tool_call_delta", :tool_call_delta] do
    {:ok,
     Event.new!(
       type: :tool_call_delta,
       index: value(map, :index) || 0,
       tool_call_id: value(map, :id),
       tool_name: value(map, :name),
       arguments_delta: value(map, :arguments_delta) || value(map, :fragment),
       raw: map
     )}
  end

  defp build(type, map) when type in ["meta", :meta] do
    {:ok,
     Event.new!(
       type: :meta,
       usage: value(map, :usage),
       finish_reason: finish_reason_to_string(value(map, :finish_reason)),
       metadata: Map.drop(map, ["type", :type]),
       raw: map
     )}
  end

  defp build(type, map) when type in ["done", :done] do
    {:ok, Event.new!(type: :done, raw: map)}
  end

  defp build(type, map) when type in ["error", :error] do
    {:ok,
     Event.new!(type: :error, message: value(map, :message) || value(map, :reason), raw: map)}
  end

  defp build(type, _map), do: {:error, "unknown CLI JSONL event type #{inspect(type)}"}

  defp value(map, key), do: map[Atom.to_string(key)] || map[key]

  defp finish_reason_to_string(nil), do: nil
  defp finish_reason_to_string(value), do: to_string(value)
end
