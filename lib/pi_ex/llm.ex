defmodule PiEx.LLM do
  @moduledoc "Bridges PiEx's agent loop to ReqLLM for real LLM calls."

  alias PiEx.Chat.Message

  @default_model "anthropic:claude-sonnet-4-20250514"

  @doc """
  Build a stream_fn compatible with PiEx.Agent.

  Streams token deltas to subscribers as `{:pi_ex, session_id, %{type: :message_delta, delta: text}}`.

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
          # Consume the raw stream, collecting text and tool calls.
          # Tool call arguments arrive as :meta chunks with :tool_call_args fragments.
          init = %{texts: [], tool_calls: [], arg_buffers: %{}, meta: %{}}

          result =
            Enum.reduce(stream_response.stream, init, fn chunk, acc ->
              case chunk.type do
                :content when is_binary(chunk.text) and chunk.text != "" ->
                  for pid <- subscribers do
                    send(pid, {:pi_ex, session_id, %{type: :message_delta, delta: chunk.text}})
                  end

                  %{acc | texts: [chunk.text | acc.texts]}

                :tool_call ->
                  id = chunk.metadata[:id] || chunk.metadata["id"]
                  index = chunk.metadata[:index] || chunk.metadata["index"]
                  tc = %{name: chunk.name, id: id, index: index}
                  %{acc | tool_calls: [tc | acc.tool_calls]}

                :meta ->
                  acc = %{acc | meta: Map.merge(acc.meta, chunk.metadata)}

                  # Accumulate tool_call_args fragments
                  case chunk.metadata do
                    %{tool_call_args: %{index: idx, fragment: frag}} ->
                      buf = Map.get(acc.arg_buffers, idx, "")
                      %{acc | arg_buffers: Map.put(acc.arg_buffers, idx, buf <> frag)}

                    _ ->
                      acc
                  end

                _ ->
                  acc
              end
            end)

          full_text = result.texts |> Enum.reverse() |> Enum.join("")

          # Merge accumulated argument JSON into tool calls
          tool_calls =
            result.tool_calls
            |> Enum.reverse()
            |> Enum.map(fn tc ->
              raw_args = Map.get(result.arg_buffers, tc.index, "{}")
              args = case Jason.decode(raw_args) do
                {:ok, map} -> map
                _ -> %{"raw" => raw_args}
              end
              %{id: tc.id, name: tc.name, arguments: args}
            end)

          # Get usage from metadata handle
          usage = ReqLLM.StreamResponse.usage(stream_response)

          assistant_msg =
            build_assistant_message(full_text, tool_calls, result.meta, call_model, usage)

          {:ok, assistant_msg}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  defp build_assistant_message(text, tool_calls, meta, model, usage) do
    pi_tool_calls =
      Enum.map(tool_calls, fn tc ->
        %PiEx.Chat.ToolCall{
          id: tc.id || "tc_#{System.unique_integer([:positive])}",
          name: tc.name,
          arguments: parse_arguments(tc.arguments)
        }
      end)

    finish_reason = meta[:finish_reason] || meta["finish_reason"]

    stop_reason =
      cond do
        pi_tool_calls != [] -> :tool_use
        finish_reason in ["tool_use", :tool_use, "tool_calls", :tool_calls] -> :tool_use
        true -> :end_turn
      end

    attrs = %{
      content: text,
      tool_calls: pi_tool_calls,
      model: to_string(model),
      provider: "anthropic",
      stop_reason: stop_reason,
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
