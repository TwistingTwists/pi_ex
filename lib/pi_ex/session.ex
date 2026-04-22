defmodule PiEx.Session do
  @moduledoc "Append-only tree operations on session state."

  alias PiEx.Chat.SessionEntry

  @doc "Generate an 8-char hex ID."
  def generate_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  @doc "Append a message entry to the session. Returns updated session."
  def append_message(session, message) do
    entry_id = generate_id()

    entry = %SessionEntry{
      id: entry_id,
      parent_id: session.leaf_id,
      type: :message,
      data: serialize_message(message),
      timestamp: DateTime.utc_now()
    }

    %{
      session
      | entries: session.entries ++ [entry],
        leaf_id: entry_id,
        messages: session.messages ++ [message]
    }
  end

  @doc "Get the path from root to current leaf (ordered root-first)."
  def get_path(session) do
    by_id = Map.new(session.entries, &{&1.id, &1})
    walk_to_root(session.leaf_id, by_id, [])
  end

  defp walk_to_root(nil, _by_id, acc), do: acc

  defp walk_to_root(id, by_id, acc) do
    case Map.fetch(by_id, id) do
      {:ok, entry} -> walk_to_root(entry.parent_id, by_id, [entry | acc])
      :error -> acc
    end
  end

  @doc "Get messages from the current path (root to leaf, only :message entries)."
  def get_messages(session) do
    session
    |> get_path()
    |> Enum.filter(&(&1.type == :message))
    |> Enum.map(&deserialize_message/1)
  end

  @doc "Branch: move leaf pointer to an earlier entry. Next append creates a new branch."
  def branch(session, entry_id) do
    if Enum.any?(session.entries, &(&1.id == entry_id)) do
      new_session = %{session | leaf_id: entry_id}
      messages = get_messages(new_session)
      %{new_session | messages: messages}
    else
      session
    end
  end

  @doc "Append a custom entry (model_change, label, etc.)."
  def append_entry(session, type, data \\ %{}) do
    entry_id = generate_id()

    entry = %SessionEntry{
      id: entry_id,
      parent_id: session.leaf_id,
      type: type,
      data: data,
      timestamp: DateTime.utc_now()
    }

    %{session | entries: session.entries ++ [entry], leaf_id: entry_id}
  end

  defp serialize_message(message) do
    %{
      id: message.id,
      role: message.role,
      content: message.content,
      tool_calls:
        Enum.map(message.tool_calls || [], fn tc ->
          %{id: tc.id, name: tc.name, arguments: tc.arguments}
        end),
      tool_call_id: message.tool_call_id,
      tool_name: message.tool_name,
      is_error: message.is_error,
      model: message.model,
      provider: message.provider,
      stop_reason: message.stop_reason,
      usage: message.usage,
      error_message: message.error_message,
      timestamp: message.timestamp
    }
  end

  @doc false
  def deserialize_message(%SessionEntry{data: data}) do
    role =
      if is_atom(data.role),
        do: data.role,
        else: String.to_existing_atom(data[:role] || data["role"])

    action =
      case role do
        :user -> :create_user
        :assistant -> :create_assistant
        :tool_result -> :create_tool_result
      end

    attrs =
      case role do
        :user ->
          %{content: data[:content] || data["content"]}

        :assistant ->
          %{
            content: data[:content] || data["content"],
            tool_calls: deserialize_tool_calls(data[:tool_calls] || data["tool_calls"] || []),
            model: data[:model] || data["model"],
            provider: data[:provider] || data["provider"],
            stop_reason: deserialize_atom(data[:stop_reason] || data["stop_reason"]),
            usage: data[:usage] || data["usage"],
            error_message: data[:error_message] || data["error_message"]
          }

        :tool_result ->
          %{
            content: data[:content] || data["content"],
            tool_call_id: data[:tool_call_id] || data["tool_call_id"],
            tool_name: data[:tool_name] || data["tool_name"],
            is_error: data[:is_error] || data["is_error"] || false
          }
      end

    Ash.Changeset.for_create(PiEx.Chat.Message, action, attrs) |> Ash.create!()
  end

  defp deserialize_tool_calls(tcs) when is_list(tcs) do
    Enum.map(tcs, fn tc ->
      %PiEx.Chat.ToolCall{
        id: tc[:id] || tc["id"],
        name: tc[:name] || tc["name"],
        arguments: tc[:arguments] || tc["arguments"] || %{}
      }
    end)
  end

  defp deserialize_tool_calls(_), do: []

  defp deserialize_atom(nil), do: nil
  defp deserialize_atom(a) when is_atom(a), do: a
  defp deserialize_atom(s) when is_binary(s), do: String.to_existing_atom(s)
end
