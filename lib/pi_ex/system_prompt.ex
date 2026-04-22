defmodule PiEx.SystemPrompt do
  @moduledoc "Composable system prompt builder inspired by pi-mono."

  @doc """
  Build a system prompt from options.

  Options:
    - `:tools` — list of tool modules (implementing PiEx.Tool), default []
    - `:cwd` — working directory string, default File.cwd!()
    - `:context_files` — list of %{path: String.t(), content: String.t()}, default: auto-discovered
    - `:custom_prompt` — if set, replaces the entire base prompt
    - `:append_prompt` — appended after the base prompt
    - `:extra_guidelines` — list of extra guideline strings to include
    - `:skills` — list of %{name: String.t(), description: String.t(), location: String.t()}, default []
  """
  def build(opts \\ []) do
    tools = Keyword.get(opts, :tools, [])
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    context_files = Keyword.get_lazy(opts, :context_files, fn -> PiEx.Context.discover(cwd) end)
    custom_prompt = Keyword.get(opts, :custom_prompt)
    append_prompt = Keyword.get(opts, :append_prompt)
    extra_guidelines = Keyword.get(opts, :extra_guidelines, [])
    skills = Keyword.get(opts, :skills, [])

    tool_names = Enum.map(tools, & &1.name())

    sections =
      []
      |> add_base(custom_prompt, tools, tool_names, extra_guidelines)
      |> add_context(context_files)
      |> add_skills(skills, tool_names)
      |> add_append(append_prompt)
      |> add_date_cwd(cwd)

    Enum.join(sections, "\n\n")
  end

  defp add_base(sections, nil, tools, tool_names, extra_guidelines) do
    preamble =
      "You are an expert coding assistant. You help users by reading files, executing commands, editing code, and writing new files."

    sections = sections ++ [preamble]

    sections =
      if tools != [] do
        tool_lines = Enum.map(tools, fn t -> "- #{t.name()}: #{t.description()}" end)
        sections ++ ["Available tools:\n" <> Enum.join(tool_lines, "\n")]
      else
        sections
      end

    guidelines = tool_guidelines(tool_names) ++ extra_guidelines ++ universal_guidelines()

    if guidelines != [] do
      lines = Enum.map(guidelines, &"- #{&1}")
      sections ++ ["Guidelines:\n" <> Enum.join(lines, "\n")]
    else
      sections
    end
  end

  defp add_base(sections, custom_prompt, _tools, _tool_names, _extra_guidelines) do
    sections ++ [custom_prompt]
  end

  defp tool_guidelines(names) do
    has_bash = "bash" in names
    has_search = Enum.any?(names, &(&1 in ["grep", "find", "ls"]))
    has_read = "read" in names
    has_edit = "edit" in names
    has_write = "write" in names

    []
    |> then(fn g ->
      cond do
        has_bash and has_search ->
          g ++ ["Prefer grep/find/ls tools over bash for file exploration"]

        has_bash ->
          g ++ ["Use bash for file operations like ls, rg, find"]

        true ->
          g
      end
    end)
    |> then(fn g ->
      if has_read, do: g ++ ["Use read to examine file contents instead of cat or sed"], else: g
    end)
    |> then(fn g ->
      if has_edit,
        do: g ++ ["Use edit for precise text replacements with exact matching"],
        else: g
    end)
    |> then(fn g ->
      if has_write, do: g ++ ["Use write only for new files or complete rewrites"], else: g
    end)
  end

  defp universal_guidelines do
    ["Be concise in your responses", "Show file paths clearly when working with files"]
  end

  defp add_context(sections, []), do: sections

  defp add_context(sections, files) do
    file_sections = Enum.map(files, fn %{path: p, content: c} -> "## #{p}\n\n#{c}" end)

    content =
      "# Project Context\n\nProject-specific instructions and guidelines:\n\n" <>
        Enum.join(file_sections, "\n\n")

    sections ++ [content]
  end

  defp add_skills(sections, [], _tool_names), do: sections

  defp add_skills(sections, skills, tool_names) do
    if "read" in tool_names do
      skill_entries =
        Enum.map(skills, fn s ->
          """
            <skill>
              <name>#{s.name}</name>
              <description>#{s.description}</description>
              <location>#{s.location}</location>
            </skill>\
          """
        end)

      text = """
      The following skills provide specialized instructions for specific tasks.
      Use the read tool to load a skill's file when the task matches its description.

      <available_skills>
      #{Enum.join(skill_entries, "\n")}
      </available_skills>\
      """

      sections ++ [text]
    else
      sections
    end
  end

  defp add_append(sections, nil), do: sections
  defp add_append(sections, text), do: sections ++ [text]

  defp add_date_cwd(sections, cwd) do
    date = Date.utc_today() |> Date.to_iso8601()
    sections ++ ["Current date: #{date}\nCurrent working directory: #{cwd}"]
  end
end
