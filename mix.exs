defmodule PiEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :pi_ex_native,
      version: "0.1.1",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "An Elixir library for building AI coding agents, OTP-native with tool system, extensions, and session persistence.",
      package: package(),
      docs: docs(),
      source_url: "https://github.com/TwistingTwists/pi_ex",
      homepage_url: "https://github.com/TwistingTwists/pi_ex",
      usage_rules: usage_rules()
    ]
  end

  defp usage_rules do
    # Example for those using claude.
    [
      file: "CLAUDE.md",
      # rules to include directly in CLAUDE.md
      # use a regex to match multiple deps, or atoms/strings for specific ones
      usage_rules: [:usage_rules, :ash, ~r/^ash_/],
      # If your CLAUDE.md is getting too big, link instead of inlining:
      usage_rules: [:usage_rules, :ash, {~r/^ash_/, link: :markdown}],
      # or use skills
      skills: [
        location: ".claude/skills",
        # Pull in pre-built skills shipped directly by packages
        package_skills: [:ash, ~r/^ash_/],
        # build skills that combine multiple usage rules
        build: [
          "ash-framework": [
            # The description tells people how to use this skill.
            description:
              "Use this skill working with Ash Framework or any of its extensions. Always consult this when making any domain changes, features or fixes.",
            # Include all Ash dependencies
            usage_rules: [:ash, ~r/^ash_/]
          ]
        ]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {PiEx.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:usage_rules, "~> 1.0", only: [:dev]},
      {:ash, "~> 3.24"},
      {:req_llm, "~> 1.10"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: "pi_ex_native",
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/TwistingTwists/pi_ex"},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PiEx",
      extras: ["README.md"],
      groups_for_modules: [
        Core: [
          PiEx,
          PiEx.Agent,
          PiEx.LLM,
          PiEx.LLM.Router,
          PiEx.LLM.CLI.Event,
          PiEx.LLM.CLI.Parser,
          PiEx.LLM.CLI.Parsers.JSONL,
          PiEx.LLM.CLI.Parsers.Shannon,
          PiEx.Turn,
          PiEx.Events
        ],
        Chat: [
          PiEx.Chat,
          PiEx.Chat.Session,
          PiEx.Chat.Message,
          PiEx.Chat.ToolCall,
          PiEx.Chat.SessionEntry
        ],
        Tools: [
          PiEx.Tool,
          PiEx.Tools,
          PiEx.Tools.Read,
          PiEx.Tools.Write,
          PiEx.Tools.Edit,
          PiEx.Tools.Bash
        ],
        Extensions: [PiEx.Extension, PiEx.Extension.Pipeline, PiEx.Extension.Loader],
        System: [PiEx.SystemPrompt, PiEx.Context, PiEx.Session, PiEx.Session.JSONL]
      ]
    ]
  end
end
