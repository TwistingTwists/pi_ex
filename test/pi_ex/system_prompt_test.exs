defmodule PiEx.SystemPromptTest do
  use ExUnit.Case, async: true

  describe "build/1 tool-dependent guidelines" do
    test "bash-only gets 'Use bash for file operations'" do
      prompt = PiEx.SystemPrompt.build(tools: [PiEx.Tools.Bash], cwd: "/tmp")
      assert prompt =~ "Use bash for file operations"
      refute prompt =~ "Prefer grep/find"
    end

    test "bash + read gets read-specific guideline" do
      prompt = PiEx.SystemPrompt.build(tools: [PiEx.Tools.Bash, PiEx.Tools.Read], cwd: "/tmp")
      assert prompt =~ "Use read to examine file contents"
      assert prompt =~ "Use bash for file operations"
    end

    test "all coding tools listed in Available tools section" do
      prompt = PiEx.SystemPrompt.build(tools: PiEx.Tools.coding_tools(), cwd: "/tmp")
      assert prompt =~ "Available tools:"
      assert prompt =~ "- read:"
      assert prompt =~ "- write:"
      assert prompt =~ "- edit:"
      assert prompt =~ "- bash:"
    end

    test "always includes universal guidelines" do
      prompt = PiEx.SystemPrompt.build(tools: [], cwd: "/tmp")
      assert prompt =~ "Be concise in your responses"
      assert prompt =~ "Show file paths clearly"
    end

    test "extra_guidelines are included" do
      prompt =
        PiEx.SystemPrompt.build(
          tools: [],
          cwd: "/tmp",
          extra_guidelines: ["Always use TypeScript"]
        )

      assert prompt =~ "Always use TypeScript"
    end
  end

  describe "build/1 context files" do
    @tag :tmp_dir
    test "includes context files in prompt", %{tmp_dir: tmp_dir} do
      inner = Path.join(tmp_dir, "project")
      File.mkdir_p!(inner)
      File.write!(Path.join(tmp_dir, "AGENTS.md"), "# Root rules\nBe careful.")
      File.write!(Path.join(inner, "AGENTS.md"), "# Project rules\nUse Elixir.")

      context = PiEx.Context.discover(inner)

      assert length(context) >= 2

      tmp_context = Enum.filter(context, &String.starts_with?(&1.path, tmp_dir))
      assert length(tmp_context) == 2
      assert hd(tmp_context).content =~ "Root rules"
      assert List.last(tmp_context).content =~ "Project rules"

      prompt = PiEx.SystemPrompt.build(tools: [], cwd: inner, context_files: tmp_context)
      assert prompt =~ "# Project Context"
      assert prompt =~ "Root rules"
      assert prompt =~ "Project rules"
    end

    @tag :tmp_dir
    test "CLAUDE.md used as fallback when no AGENTS.md", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "# Claude rules")
      context = PiEx.Context.discover(tmp_dir)
      assert length(context) >= 1
      assert Enum.any?(context, &(&1.content =~ "Claude rules"))
    end
  end

  describe "build/1 custom prompt" do
    test "custom_prompt replaces base but keeps date and cwd" do
      prompt = PiEx.SystemPrompt.build(custom_prompt: "You are a pirate.", cwd: "/tmp")
      assert prompt =~ "You are a pirate."
      refute prompt =~ "expert coding assistant"
      assert prompt =~ "Current date:"
      assert prompt =~ "Current working directory: /tmp"
    end

    test "append_prompt is appended" do
      prompt = PiEx.SystemPrompt.build(tools: [], cwd: "/tmp", append_prompt: "EXTRA INSTRUCTION")
      assert prompt =~ "EXTRA INSTRUCTION"
    end
  end

  describe "build/1 skills" do
    test "skills included when read tool is available" do
      skills = [
        %{name: "test-skill", description: "A test skill", location: "/skills/test/SKILL.md"}
      ]

      prompt = PiEx.SystemPrompt.build(tools: [PiEx.Tools.Read], cwd: "/tmp", skills: skills)
      assert prompt =~ "<available_skills>"
      assert prompt =~ "<name>test-skill</name>"
      assert prompt =~ "<description>A test skill</description>"
    end

    test "skills NOT included when read tool is absent" do
      skills = [
        %{name: "test-skill", description: "A test skill", location: "/skills/test/SKILL.md"}
      ]

      prompt = PiEx.SystemPrompt.build(tools: [PiEx.Tools.Bash], cwd: "/tmp", skills: skills)
      refute prompt =~ "<available_skills>"
    end
  end

  describe "build/1 date and cwd" do
    test "includes current date and cwd" do
      prompt = PiEx.SystemPrompt.build(tools: [], cwd: "/home/user/project")
      assert prompt =~ "Current date: #{Date.utc_today() |> Date.to_iso8601()}"
      assert prompt =~ "Current working directory: /home/user/project"
    end
  end
end
