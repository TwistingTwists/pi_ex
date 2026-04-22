defmodule PiEx.Chat.MessageTest do
  use ExUnit.Case, async: true

  alias PiEx.Chat.Message

  describe "create_user" do
    test "creates a user message" do
      msg =
        Message
        |> Ash.Changeset.for_create(:create_user, %{content: "hello"})
        |> Ash.create!()

      assert msg.role == :user
      assert msg.content == "hello"
      assert msg.id != nil
      assert msg.timestamp != nil
    end
  end

  describe "create_assistant" do
    test "creates an assistant message with tool_calls" do
      msg =
        Message
        |> Ash.Changeset.for_create(:create_assistant, %{
          content: "Let me read that file.",
          tool_calls: [%{id: "call_123", name: "read", arguments: %{"path" => "foo.ex"}}],
          model: "claude-sonnet-4-20250514",
          provider: "anthropic",
          stop_reason: :tool_use
        })
        |> Ash.create!()

      assert msg.role == :assistant
      assert msg.content == "Let me read that file."
      assert length(msg.tool_calls) == 1
      assert hd(msg.tool_calls).id == "call_123"
      assert hd(msg.tool_calls).name == "read"
      assert hd(msg.tool_calls).arguments == %{"path" => "foo.ex"}
      assert msg.model == "claude-sonnet-4-20250514"
      assert msg.stop_reason == :tool_use
    end
  end

  describe "create_tool_result" do
    test "creates a tool_result message" do
      msg =
        Message
        |> Ash.Changeset.for_create(:create_tool_result, %{
          content: "file contents here",
          tool_call_id: "call_123",
          tool_name: "read",
          is_error: false
        })
        |> Ash.create!()

      assert msg.role == :tool_result
      assert msg.tool_call_id == "call_123"
      assert msg.tool_name == "read"
      assert msg.is_error == false
    end
  end

  describe "validations" do
    test "rejects invalid role via direct create" do
      assert_raise Ash.Error.Invalid, fn ->
        Message
        |> Ash.Changeset.for_create(:create_user, %{content: "hi"})
        |> Ash.Changeset.force_change_attribute(:role, :invalid_role)
        |> Ash.create!()
      end
    end
  end
end
