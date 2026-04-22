defmodule PiEx.Extension do
  @moduledoc "Behaviour for pi_ex extensions."

  @type event_name ::
          :session_start
          | :before_prompt
          | :context
          | :turn_start
          | :turn_end
          | :tool_call
          | :tool_result
          | :agent_end
          | :session_shutdown

  @type event :: {event_name(), map()}
  @type context :: %{session_id: String.t(), cwd: String.t(), model: String.t() | nil}

  @callback init(config :: map()) :: {:ok, state :: term()} | {:error, term()}
  @callback handle_event(event_name(), payload :: map(), context(), state :: term()) ::
              {:ok, state :: term()}
              | {:mutate, changes :: map(), state :: term()}
              | {:block, reason :: String.t(), state :: term()}
  @callback tools() :: [module()]

  @optional_callbacks [tools: 0]
end
