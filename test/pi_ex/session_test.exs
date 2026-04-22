defmodule PiEx.SessionTest do
  use ExUnit.Case, async: true

  alias PiEx.Chat.{Message, Session}
  alias PiEx.Session, as: Sess

  defp create_session do
    Ash.Changeset.for_create(Session, :start, %{
      system_prompt: "test",
      cwd: "/tmp"
    })
    |> Ash.create!()
  end

  defp user_msg(text) do
    Ash.Changeset.for_create(Message, :create_user, %{content: text}) |> Ash.create!()
  end

  defp assistant_msg(text) do
    Ash.Changeset.for_create(Message, :create_assistant, %{content: text, stop_reason: :end_turn})
    |> Ash.create!()
  end

  test "append_message adds entries with correct parent chain" do
    session = create_session()
    assert session.entries == []
    assert session.leaf_id == nil

    msg1 = user_msg("hello")
    session = Sess.append_message(session, msg1)
    assert length(session.entries) == 1
    assert hd(session.entries).parent_id == nil
    assert session.leaf_id == hd(session.entries).id

    msg2 = assistant_msg("hi back")
    session = Sess.append_message(session, msg2)
    assert length(session.entries) == 2
    [e1, e2] = session.entries
    assert e2.parent_id == e1.id
    assert session.leaf_id == e2.id
  end

  test "get_path returns root-to-leaf order" do
    session = create_session()
    session = Sess.append_message(session, user_msg("a"))
    session = Sess.append_message(session, assistant_msg("b"))
    session = Sess.append_message(session, user_msg("c"))

    path = Sess.get_path(session)
    assert length(path) == 3
    types = Enum.map(path, & &1.type)
    assert types == [:message, :message, :message]
    assert hd(path).parent_id == nil
  end

  test "branch creates divergent path" do
    session = create_session()
    session = Sess.append_message(session, user_msg("a"))
    branch_point = session.leaf_id

    session = Sess.append_message(session, assistant_msg("b"))
    session = Sess.append_message(session, user_msg("c"))
    assert length(session.entries) == 3

    session = Sess.branch(session, branch_point)
    assert session.leaf_id == branch_point
    assert length(session.messages) == 1

    session = Sess.append_message(session, assistant_msg("d"))
    assert length(session.entries) == 4

    new_entry = List.last(session.entries)
    assert new_entry.parent_id == branch_point

    path = Sess.get_path(session)
    assert length(path) == 2
  end
end
