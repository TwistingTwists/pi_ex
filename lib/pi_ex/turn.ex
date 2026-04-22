defmodule PiEx.Turn do
  @moduledoc "Pure functions for agent turn logic."

  alias PiEx.Chat.Message

  @doc """
  Convert PiEx messages to ReqLLM.Message structs for the LLM call.
  """
  def to_llm_messages(messages) do
    messages
    |> Enum.filter(&(&1.role in [:user, :assistant, :tool_result]))
    |> Enum.map(&to_llm_message/1)
  end

  defp to_llm_message(%Message{role: :user, content: content}) do
    %ReqLLM.Message{
      role: :user,
      content: [%ReqLLM.Message.ContentPart{type: :text, text: content}]
    }
  end

  defp to_llm_message(%Message{role: :assistant, content: content, tool_calls: tool_calls})
       when is_list(tool_calls) and tool_calls != [] do
    %ReqLLM.Message{
      role: :assistant,
      content: [%ReqLLM.Message.ContentPart{type: :text, text: content || ""}],
      tool_calls:
        Enum.map(tool_calls, fn tc ->
          ReqLLM.ToolCall.new(tc.id, tc.name, Jason.encode!(tc.arguments || %{}))
        end)
    }
  end

  defp to_llm_message(%Message{role: :assistant, content: content}) do
    %ReqLLM.Message{
      role: :assistant,
      content: [%ReqLLM.Message.ContentPart{type: :text, text: content || ""}]
    }
  end

  defp to_llm_message(%Message{role: :tool_result, content: content, tool_call_id: tool_call_id}) do
    %ReqLLM.Message{
      role: :tool,
      content: [%ReqLLM.Message.ContentPart{type: :text, text: content || ""}],
      tool_call_id: tool_call_id
    }
  end

  @doc """
  Extract tool calls from an assistant message's response.
  """
  def extract_tool_calls(%Message{role: :assistant, tool_calls: tool_calls})
      when is_list(tool_calls) and tool_calls != [] do
    Enum.map(tool_calls, fn tc -> %{id: tc.id, name: tc.name, arguments: tc.arguments} end)
  end

  def extract_tool_calls(_), do: []

  @doc """
  Execute tool calls in parallel and return tool result messages.
  """
  def execute_tools(tool_calls, tool_map, context, hooks \\ %{}) do
    PiEx.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      tool_calls,
      fn tc -> execute_single_tool(tc, tool_map, context, hooks) end,
      max_concurrency: 4,
      ordered: true
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp execute_single_tool(tool_call, tool_map, context, hooks) do
    # Phase 1 — Prepare
    case Map.fetch(tool_map, tool_call.name) do
      {:ok, tool_mod} ->
        before_result =
          case Map.get(hooks, :before_tool_call) do
            nil -> :ok
            hook -> hook.(tool_call, tool_call.arguments, context)
          end

        case before_result do
          {:block, reason} ->
            create_tool_result(tool_call, to_string(reason), true)

          :ok ->
            # Phase 2 — Execute
            {content, is_error} =
              case tool_mod.execute(tool_call.arguments, context) do
                {:ok, parts} ->
                  {Enum.map_join(parts, "\n", fn %{text: t} -> t end), false}

                {:error, reason} ->
                  {to_string(reason), true}
              end

            # Phase 3 — Finalize
            {content, is_error} =
              case Map.get(hooks, :after_tool_call) do
                nil ->
                  {content, is_error}

                hook ->
                  case hook.(tool_call, tool_call.arguments, content, is_error, context) do
                    :ok ->
                      {content, is_error}

                    {:override, %{content: new_content, is_error: new_is_error}} ->
                      {new_content, new_is_error}
                  end
              end

            create_tool_result(tool_call, content, is_error)
        end

      :error ->
        create_tool_result(tool_call, "Unknown tool: #{tool_call.name}", true)
    end
  end

  defp create_tool_result(tool_call, content, is_error) do
    Ash.Changeset.for_create(Message, :create_tool_result, %{
      content: content,
      tool_call_id: tool_call.id,
      tool_name: tool_call.name,
      is_error: is_error
    })
    |> Ash.create!()
  end

  @doc """
  Determine what to do next based on assistant message.
  """
  def next_action(%Message{stop_reason: :error}), do: :error
  def next_action(%Message{stop_reason: :aborted}), do: :aborted
  def next_action(%Message{stop_reason: :tool_use}), do: :continue

  def next_action(%Message{tool_calls: tc}) when is_list(tc) and tc != [],
    do: :continue

  def next_action(_), do: :done

  @doc """
  Build a tool_map from a list of tool modules.
  """
  def build_tool_map(tool_modules) do
    Map.new(tool_modules, fn mod -> {mod.name(), mod} end)
  end
end
