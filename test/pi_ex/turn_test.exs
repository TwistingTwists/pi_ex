defmodule PiEx.TurnTest do
  use ExUnit.Case, async: true

  alias PiEx.Chat.Message
  alias PiEx.Turn

  defmodule FakeTool do
    @behaviour PiEx.Tool
    def name, do: "fake"
    def description, do: "A fake tool"
    def parameters, do: %{}

    def execute(%{"input" => input}, _ctx),
      do: {:ok, [%{type: :text, text: "Got: #{input}"}]}
  end

  defmodule ErrorTool do
    @behaviour PiEx.Tool
    def name, do: "error_tool"
    def description, do: "Always errors"
    def parameters, do: %{}
    def execute(_args, _ctx), do: {:error, "something went wrong"}
  end

  defp create_user(content) do
    Ash.Changeset.for_create(Message, :create_user, %{content: content}) |> Ash.create!()
  end

  defp create_assistant(attrs) do
    Ash.Changeset.for_create(Message, :create_assistant, attrs) |> Ash.create!()
  end

  defp create_tool_result(attrs) do
    Ash.Changeset.for_create(Message, :create_tool_result, attrs) |> Ash.create!()
  end

  describe "to_llm_messages/1" do
    test "converts user message" do
      msg = create_user("hello")
      [llm] = Turn.to_llm_messages([msg])
      assert llm.role == :user
      assert [%ReqLLM.Message.ContentPart{type: :text, text: "hello"}] = llm.content
    end

    test "converts assistant message without tool_calls" do
      msg = create_assistant(%{content: "hi there"})
      [llm] = Turn.to_llm_messages([msg])
      assert llm.role == :assistant
      assert [%{type: :text, text: "hi there"}] = llm.content
      assert llm.tool_calls == nil
    end

    test "converts assistant message with tool_calls" do
      msg =
        create_assistant(%{
          content: "",
          tool_calls: [%{id: "call_1", name: "read", arguments: %{"path" => "/tmp"}}]
        })

      [llm] = Turn.to_llm_messages([msg])
      assert llm.role == :assistant
      assert [%ReqLLM.ToolCall{id: "call_1"}] = llm.tool_calls
    end

    test "converts tool_result message" do
      msg =
        create_tool_result(%{content: "file contents", tool_call_id: "call_1", tool_name: "read"})

      [llm] = Turn.to_llm_messages([msg])
      assert llm.role == :tool
      assert llm.tool_call_id == "call_1"
    end
  end

  describe "extract_tool_calls/1" do
    test "extracts tool calls from assistant message" do
      msg =
        create_assistant(%{
          content: "",
          tool_calls: [%{id: "call_1", name: "read", arguments: %{"path" => "/tmp"}}]
        })

      assert [%{id: "call_1", name: "read", arguments: %{"path" => "/tmp"}}] =
               Turn.extract_tool_calls(msg)
    end

    test "returns empty list for user message" do
      assert [] == Turn.extract_tool_calls(create_user("hi"))
    end

    test "returns empty list for assistant without tool_calls" do
      assert [] == Turn.extract_tool_calls(create_assistant(%{content: "hello"}))
    end
  end

  describe "execute_tools/3" do
    test "executes tool calls and returns results" do
      tool_map = Turn.build_tool_map([FakeTool])

      tc =
        create_assistant(%{
          content: "",
          tool_calls: [%{id: "call_1", name: "fake", arguments: %{"input" => "test"}}]
        })

      tool_calls = Turn.extract_tool_calls(tc)
      [result] = Turn.execute_tools(tool_calls, tool_map, %{})

      assert result.role == :tool_result
      assert result.content == "Got: test"
      assert result.tool_call_id == "call_1"
      assert result.is_error == false
    end

    test "handles tool errors" do
      tool_map = Turn.build_tool_map([ErrorTool])

      tc =
        create_assistant(%{
          content: "",
          tool_calls: [%{id: "call_2", name: "error_tool", arguments: %{}}]
        })

      tool_calls = Turn.extract_tool_calls(tc)
      [result] = Turn.execute_tools(tool_calls, tool_map, %{})

      assert result.is_error == true
      assert result.content == "something went wrong"
    end

    test "handles unknown tool" do
      tc =
        create_assistant(%{
          content: "",
          tool_calls: [%{id: "call_3", name: "nonexistent", arguments: %{}}]
        })

      tool_calls = Turn.extract_tool_calls(tc)
      [result] = Turn.execute_tools(tool_calls, %{}, %{})

      assert result.is_error == true
      assert result.content =~ "Unknown tool"
    end
  end

  describe "next_action/1" do
    test "returns :error for error stop_reason" do
      msg = create_assistant(%{content: "", stop_reason: :error})
      assert :error == Turn.next_action(msg)
    end

    test "returns :aborted for aborted stop_reason" do
      msg = create_assistant(%{content: "", stop_reason: :aborted})
      assert :aborted == Turn.next_action(msg)
    end

    test "returns :continue for tool_use stop_reason" do
      msg = create_assistant(%{content: "", stop_reason: :tool_use})
      assert :continue == Turn.next_action(msg)
    end

    test "returns :continue when tool_calls present" do
      msg =
        create_assistant(%{
          content: "",
          tool_calls: [%{id: "c1", name: "read", arguments: %{}}]
        })

      assert :continue == Turn.next_action(msg)
    end

    test "returns :done for plain assistant message" do
      msg = create_assistant(%{content: "done"})
      assert :done == Turn.next_action(msg)
    end
  end

  describe "build_tool_map/1" do
    test "builds map from tool modules" do
      map = Turn.build_tool_map([FakeTool, ErrorTool])
      assert map["fake"] == FakeTool
      assert map["error_tool"] == ErrorTool
      assert map_size(map) == 2
    end
  end
end
