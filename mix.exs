defmodule PiEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :pi_ex,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
      {:jason, "~> 1.4"}
    ]
  end
end
