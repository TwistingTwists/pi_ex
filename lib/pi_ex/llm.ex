defmodule PiEx.LLM do
  @moduledoc """
  Backwards-compatible entry point for PiEx LLM streaming.

  The implementation now delegates to `PiEx.LLM.Router`, which supports any
  ReqLLM provider/model, OpenAI-compatible inline models, Google/Anthropic/OpenAI,
  CLI JSONL backends, and route/account load balancing.

  Prefer using `PiEx.LLM.Router` directly when you need multiple routes:

      stream_fn =
        PiEx.LLM.Router.stream_fn(
          strategy: :round_robin,
          routes: [
            [name: :acct_a, model: "openai:gpt-4.1", api_key: {:env, "OPENAI_KEY_A"}],
            [name: :acct_b, model: "openai:gpt-4.1", api_key: {:env, "OPENAI_KEY_B"}]
          ]
        )

  For the old single-model style, this module remains enough:

      PiEx.LLM.stream_fn(model: "anthropic:claude-sonnet-4-20250514")
  """

  @doc "Build a `PiEx.Agent`-compatible stream function."
  @spec stream_fn(keyword() | map()) :: PiEx.Agent.stream_fn()
  def stream_fn(opts \\ []), do: PiEx.LLM.Router.stream_fn(opts)

  @doc "Returns the default model string."
  def default_model, do: PiEx.LLM.Router.default_model()

  @doc "Returns supported LLM runtime features."
  defdelegate features, to: PiEx.LLM.Router

  @doc "Returns the staged LLM runtime support plan."
  defdelegate plan, to: PiEx.LLM.Router
end
