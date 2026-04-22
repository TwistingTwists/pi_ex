defmodule PiEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :pi_ex,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "An Elixir library for building AI coding agents, OTP-native with tool system, extensions, and session persistence.",
      package: package(),
      docs: docs(),
      source_url: "https://github.com/TwistingTwists/pi_ex",
      homepage_url: "https://github.com/TwistingTwists/pi_ex"
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
        Core: [PiEx, PiEx.Agent, PiEx.LLM, PiEx.Turn, PiEx.Events],
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
