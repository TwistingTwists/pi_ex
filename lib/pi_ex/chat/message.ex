defmodule PiEx.Chat.Message do
  use Ash.Resource, data_layer: :embedded

  attributes do
    uuid_v7_primary_key :id

    attribute :role, :atom do
      constraints one_of: [:user, :assistant, :tool_result]
      allow_nil? false
      public? true
    end

    attribute :content, :string, public?: true
    attribute :tool_calls, {:array, PiEx.Chat.ToolCall}, default: [], public?: true
    attribute :tool_call_id, :string, public?: true
    attribute :tool_name, :string, public?: true
    attribute :is_error, :boolean, default: false, public?: true
    attribute :model, :string, public?: true
    attribute :provider, :string, public?: true

    attribute :stop_reason, :atom do
      constraints one_of: [:end_turn, :tool_use, :error, :aborted]
      public? true
    end

    attribute :usage, :map, public?: true
    attribute :error_message, :string, public?: true
    attribute :timestamp, :utc_datetime_usec, default: &DateTime.utc_now/0, public?: true
  end

  actions do
    default_accept :*
    defaults [:read, :create]

    create :create_user do
      accept [:content]
      change set_attribute(:role, :user)
    end

    create :create_assistant do
      accept [:content, :tool_calls, :model, :provider, :stop_reason, :usage, :error_message]
      change set_attribute(:role, :assistant)
    end

    create :create_tool_result do
      accept [:content, :tool_call_id, :tool_name, :is_error]
      change set_attribute(:role, :tool_result)
    end
  end
end
