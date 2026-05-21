defmodule PiEx.LLM.CLI.Parser do
  @moduledoc """
  Behaviour for parsing arbitrary CLI LLM stdout into normalized events.

  Each CLI route may specify a parser module:

      [backend: :jsonl_cli, command: [...], parser: MyParser]
      [backend: :jsonl_cli, command: [...], parser: {MyParser, opts}]

  Parser modules receive one stdout line at a time and return zero or more
  `%PiEx.LLM.CLI.Event{}` structs. Parser state is per CLI process.
  """

  alias PiEx.LLM.CLI.Event

  @type state :: term()
  @type context :: %{optional(:route) => map(), optional(:model) => term()}

  @callback init(keyword() | map()) :: {:ok, state()} | {:error, term()}
  @callback parse_line(String.t(), state(), context()) ::
              {:ok, [Event.t()], state()} | {:error, term()}

  @doc false
  def normalize(nil), do: {PiEx.LLM.CLI.Parsers.JSONL, []}
  def normalize(module) when is_atom(module), do: {module, []}
  def normalize({module, opts}) when is_atom(module), do: {module, opts || []}
end
