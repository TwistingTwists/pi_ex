defmodule OrchestratorDemo.DemoLLM do
  @moduledoc """
  Deterministic, offline LLM for the IEx demo.

  The first agent turn asks PiEx to run the `read` tool. After the tool result is
  present, the second turn returns a final assistant response containing the tool
  output. This keeps the example self-contained while exercising PiEx's real
  agent/tool loop.
  """

  alias PiEx.Chat.Message

  @doc "Build a `PiEx.Agent` compatible stream function."
  def stream_fn(opts \\ []) do
    read_path = Keyword.get(opts, :read_path, "sample.txt")

    fn messages, _system_prompt, _tools, _agent_opts ->
      case latest_tool_result(messages) do
        nil -> tool_call_response(read_path)
        content -> final_response(content)
      end
    end
  end

  defp latest_tool_result(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{role: :tool_result, content: content} -> content
      _message -> nil
    end)
  end

  defp tool_call_response(read_path) do
    Message
    |> Ash.Changeset.for_create(:create_assistant, %{
      content: "I'll inspect #{read_path} with the read tool.",
      tool_calls: [%{id: "demo_read_1", name: "read", arguments: %{"path" => read_path}}],
      stop_reason: :tool_use,
      model: "offline-demo"
    })
    |> Ash.create!()
    |> then(&{:ok, &1})
  end

  defp final_response(content) do
    Message
    |> Ash.Changeset.for_create(:create_assistant, %{
      content: "PiEx read the file through the orchestrator. Contents:\n\n#{content}",
      stop_reason: :end_turn,
      model: "offline-demo"
    })
    |> Ash.create!()
    |> then(&{:ok, &1})
  end
end
