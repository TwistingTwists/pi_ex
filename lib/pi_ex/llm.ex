defmodule PiEx.LLM do
  @moduledoc "Bridges PiEx's agent loop to ReqLLM for real LLM calls."

  alias PiEx.Chat.Message

  @default_model "anthropic:claude-sonnet-4-20250514"

  @doc """
  Build a stream_fn compatible with PiEx.Agent.

  The returned function streams token deltas to the calling process as
  `{:llm_delta, text}` messages, then returns the full assistant message.

  Options:
    - `:model` — model spec string (default: #{@default_model})
    - `:api_key` — Anthropic API key (default: from ANTHROPIC_API_KEY env var)
  """
  def stream_fn(opts \\ []) do
    model = Keyword.get(opts, :model, @default_model)

    api_key =
      Keyword.get_lazy(opts, :api_key, fn ->
        System.get_env("ANTHROPIC_API_KEY") ||
          raise "Set ANTHROPIC_API_KEY environment variable"
      end)

    fn messages, system_prompt, tools, call_opts ->
      llm_messages = PiEx.Turn.to_llm_messages(messages)
      subscribers = Keyword.get(call_opts, :subscribers, MapSet.new())
      session_id = Keyword.get(call_opts, :session_id)

      req_tools =
        Enum.map(tools, fn tool_mod ->
          ReqLLM.Tool.new!(
            name: tool_mod.name(),
            description: tool_mod.description(),
            parameter_schema: tool_mod.parameters(),
            callback: fn _args -> {:ok, "noop"} end
          )
        end)

      req_opts = [
        system_prompt: system_prompt,
        tools: req_tools,
        provider_options: [access_token: api_key]
      ]

      call_model = Keyword.get(call_opts, :model) || model

      case ReqLLM.stream_text(call_model, llm_messages, req_opts) do
        {:ok, stream_response} ->
          # Stream tokens to caller, collect full text
          full_text =
            stream_response
            |> ReqLLM.StreamResponse.tokens()
            |> Enum.map_join("", fn token ->
              for pid <- subscribers do
                send(pid, {:pi_ex, session_id, %{type: :message_delta, delta: token}})
              end

              token
            end)

          # Get metadata after stream is consumed
          usage = ReqLLM.StreamResponse.usage(stream_response)

          # Convert to full response for tool call extraction
          case ReqLLM.StreamResponse.to_response(stream_response) do
            {:ok, response} ->
              classified = ReqLLM.Response.classify(response)
              assistant_msg = build_assistant_message(full_text, classified, response, usage)
              {:ok, assistant_msg}

            {:error, _} ->
              # Fallback: build message from streamed text (no tool calls)
              assistant_msg = build_simple_message(full_text, call_model, usage)
              {:ok, assistant_msg}
          end

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  defp build_assistant_message(full_text, classified, response, usage) do
    tool_calls =
      Enum.map(classified.tool_calls, fn tc ->
        %PiEx.Chat.ToolCall{
          id: tc.id,
          name: tc.name,
          arguments: parse_arguments(tc.arguments)
        }
      end)

    stop_reason =
      case classified.type do
        :tool_calls -> :tool_use
        :final_answer -> :end_turn
      end

    attrs = %{
      content: full_text,
      tool_calls: tool_calls,
      model: response.model,
      provider: "anthropic",
      stop_reason: stop_reason,
      usage: usage
    }

    Ash.Changeset.for_create(Message, :create_assistant, attrs) |> Ash.create!()
  end

  defp build_simple_message(text, model, usage) do
    attrs = %{
      content: text,
      model: to_string(model),
      provider: "anthropic",
      stop_reason: :end_turn,
      usage: usage
    }

    Ash.Changeset.for_create(Message, :create_assistant, attrs) |> Ash.create!()
  end

  defp parse_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, map} -> map
      _ -> %{"raw" => args}
    end
  end

  defp parse_arguments(args) when is_map(args), do: args
  defp parse_arguments(_), do: %{}

  @doc "Returns the default model string."
  def default_model, do: @default_model
end
