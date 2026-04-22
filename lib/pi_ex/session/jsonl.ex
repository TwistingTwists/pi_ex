defmodule PiEx.Session.JSONL do
  @moduledoc "Save/load sessions as JSONL files."

  alias PiEx.Chat.{Session, SessionEntry}

  @doc "Save session to a JSONL file. Each line is one entry."
  def save(%Session{} = session, path) do
    File.mkdir_p!(Path.dirname(path))

    header = %{
      type: "header",
      version: 1,
      session_id: session.id,
      cwd: session.cwd,
      leaf_id: session.leaf_id,
      created_at: session.created_at
    }

    lines = [Jason.encode!(header)]

    entry_lines =
      Enum.map(session.entries, fn entry ->
        Jason.encode!(%{
          type: to_string(entry.type),
          id: entry.id,
          parent_id: entry.parent_id,
          data: entry.data,
          timestamp: entry.timestamp
        })
      end)

    content = Enum.join(lines ++ entry_lines, "\n") <> "\n"
    File.write!(path, content)
    :ok
  end

  @doc "Load session from a JSONL file."
  def load(path) do
    lines = path |> File.read!() |> String.split("\n", trim: true)

    [header_line | entry_lines] = lines
    header = Jason.decode!(header_line)

    entries =
      Enum.map(entry_lines, fn line ->
        parsed = Jason.decode!(line)

        %SessionEntry{
          id: parsed["id"],
          parent_id: parsed["parent_id"],
          type: String.to_existing_atom(parsed["type"]),
          data: atomize_keys(parsed["data"]),
          timestamp: parse_timestamp(parsed["timestamp"])
        }
      end)

    session = %Session{
      id: header["session_id"],
      status: :idle,
      cwd: header["cwd"],
      leaf_id: header["leaf_id"],
      entries: entries,
      messages: [],
      steering_queue: [],
      created_at: parse_timestamp(header["created_at"])
    }

    messages = PiEx.Session.get_messages(session)
    %{session | messages: messages}
  end

  defp parse_timestamp(nil), do: DateTime.utc_now()
  defp parse_timestamp(%DateTime{} = dt), do: dt

  defp parse_timestamp(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), atomize_keys(v)}
      {k, v} -> {k, atomize_keys(v)}
    end)
  end

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(other), do: other
end
