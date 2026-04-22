defmodule PiEx.Session.JSONLTest do
  use ExUnit.Case, async: true

  alias PiEx.Chat.{Message, Session}

  @tag :tmp_dir
  test "save and load round-trip preserves session", %{tmp_dir: tmp_dir} do
    session =
      Ash.Changeset.for_create(Session, :start, %{
        system_prompt: "Be helpful",
        cwd: "/home/user/project"
      })
      |> Ash.create!()

    msg1 = Ash.Changeset.for_create(Message, :create_user, %{content: "hello"}) |> Ash.create!()
    session = PiEx.Session.append_message(session, msg1)

    msg2 =
      Ash.Changeset.for_create(Message, :create_assistant, %{
        content: "hi there",
        stop_reason: :end_turn,
        model: "test-model"
      })
      |> Ash.create!()

    session = PiEx.Session.append_message(session, msg2)

    msg3 =
      Ash.Changeset.for_create(Message, :create_user, %{content: "thanks"}) |> Ash.create!()

    session = PiEx.Session.append_message(session, msg3)

    path = Path.join(tmp_dir, "test-session.jsonl")
    :ok = PiEx.Session.JSONL.save(session, path)

    lines = path |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 4

    loaded = PiEx.Session.JSONL.load(path)

    assert loaded.id == session.id
    assert loaded.cwd == "/home/user/project"
    assert loaded.leaf_id == session.leaf_id
    assert length(loaded.entries) == 3

    assert length(loaded.messages) == 3
    assert Enum.at(loaded.messages, 0).role == :user
    assert Enum.at(loaded.messages, 0).content == "hello"
    assert Enum.at(loaded.messages, 1).role == :assistant
    assert Enum.at(loaded.messages, 1).content == "hi there"
    assert Enum.at(loaded.messages, 2).role == :user
    assert Enum.at(loaded.messages, 2).content == "thanks"

    [e1, e2, e3] = loaded.entries
    assert e1.parent_id == nil
    assert e2.parent_id == e1.id
    assert e3.parent_id == e2.id
  end

  @tag :tmp_dir
  test "save and load preserves branches", %{tmp_dir: tmp_dir} do
    session = Ash.Changeset.for_create(Session, :start, %{cwd: "/tmp"}) |> Ash.create!()

    msg1 =
      Ash.Changeset.for_create(Message, :create_user, %{content: "start"}) |> Ash.create!()

    session = PiEx.Session.append_message(session, msg1)
    branch_point = session.leaf_id

    msg2 =
      Ash.Changeset.for_create(Message, :create_assistant, %{
        content: "path A",
        stop_reason: :end_turn
      })
      |> Ash.create!()

    session = PiEx.Session.append_message(session, msg2)

    session = PiEx.Session.branch(session, branch_point)

    msg3 =
      Ash.Changeset.for_create(Message, :create_assistant, %{
        content: "path B",
        stop_reason: :end_turn
      })
      |> Ash.create!()

    session = PiEx.Session.append_message(session, msg3)

    path = Path.join(tmp_dir, "branched.jsonl")
    :ok = PiEx.Session.JSONL.save(session, path)
    loaded = PiEx.Session.JSONL.load(path)

    assert length(loaded.entries) == 3

    assert length(loaded.messages) == 2
    assert Enum.at(loaded.messages, 0).content == "start"
    assert Enum.at(loaded.messages, 1).content == "path B"
  end
end
