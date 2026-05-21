defmodule PiEx.LLM.CLI.Event do
  @moduledoc """
  Normalized event emitted by CLI LLM parsers.

  CLI tools do not share one streaming protocol. Parser modules convert their
  native stdout lines into this embedded Ash resource so the router can consume a
  stable shape.
  """

  use Ash.Resource, data_layer: :embedded

  @type event_type ::
          :content | :thinking | :tool_call | :tool_call_delta | :meta | :done | :error | :ignore

  attributes do
    uuid_v7_primary_key :id

    attribute :type, :atom do
      description "Normalized event kind. Example: Shannon `type=result` becomes `:meta`; canonical `{\"type\":\"message_delta\",\"delta\":\"hi\"}` becomes `:content`."

      constraints one_of: [
                    :content,
                    :thinking,
                    :tool_call,
                    :tool_call_delta,
                    :meta,
                    :done,
                    :error,
                    :ignore
                  ]

      allow_nil? false
      public? true
    end

    attribute :text, :string do
      description "Complete visible text emitted by this line. Example: `{\"type\":\"content\",\"text\":\"hello \"}` stores `hello ` including the trailing space."
      constraints trim?: false
      public? true
    end

    attribute :delta, :string do
      description "Alternate token delta field for CLIs that call streamed text `delta` instead of `text`. Example: `{\"delta\":\"wor\"}`."
      constraints trim?: false
      public? true
    end

    attribute :tool_call_id, :string do
      description "Provider/CLI tool call id used to correlate later tool results. Example: Claude/Shannon tool-use block id `toolu_01abc` or OpenAI-style `call_123`."
      public? true
    end

    attribute :tool_name, :string do
      description "Tool/function name requested by the model. Example: Shannon Claude block `%{\"type\" => \"tool_use\", \"name\" => \"read\"}` stores `read`."
      public? true
    end

    attribute :arguments, :map do
      description "Fully parsed tool arguments. Example: `{\"path\":\"mix.exs\"}` for PiEx's `read` tool."
      default %{}
      public? true
    end

    attribute :arguments_delta, :string do
      description "Raw JSON argument fragment for streaming tool calls. Example fragments: `{\"path\"` then `:\"mix.exs\"}` for index `0`."
      constraints trim?: false
      public? true
    end

    attribute :index, :integer do
      description "Streaming tool-call slot for merging argument fragments. Example: OpenAI-compatible CLIs emit index `0` for the first parallel tool call."
      default 0
      public? true
    end

    attribute :usage, :map do
      description "Token/cost usage copied from final records. Example: Shannon result `usage: %{\"input_tokens\" => 12, \"output_tokens\" => 1}`."
      public? true
    end

    attribute :finish_reason, :string do
      description "Provider stop reason before PiEx normalization. Example: `tool_calls` becomes assistant stop reason `:tool_use`; `end_turn` becomes `:end_turn`."
      public? true
    end

    attribute :message, :string do
      description "Human-readable CLI error message. Example: Shannon parser stores `Missing required executable: tmux` on `:error` events."
      public? true
    end

    attribute :metadata, :map do
      description "Non-content metadata that should survive parsing. Example: Shannon `shannon_session` fields like transcript_path and tmux_session."
      default %{}
      public? true
    end

    attribute :raw, :map do
      description "Original decoded JSON line for debugging parser differences. Example: the full Shannon `assistant` or canonical `tool_call_delta` object."
      default %{}
      public? true
    end
  end

  actions do
    default_accept :*
    defaults [:read]

    create :new do
      primary? true
      accept :*
    end
  end

  @doc "Build a normalized CLI event."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    __MODULE__
    |> Ash.Changeset.for_create(:new, Map.new(attrs))
    |> Ash.create!()
  end
end
