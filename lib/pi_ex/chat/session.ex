defmodule PiEx.Chat.Session do
  @moduledoc "Session state as an Ash embedded resource."
  use Ash.Resource, data_layer: :embedded

  attributes do
    uuid_v7_primary_key :id

    attribute :status, :atom do
      constraints one_of: [:idle, :streaming, :executing_tools]
      default :idle
      allow_nil? false
      public? true
    end

    attribute :system_prompt, :string, public?: true
    attribute :cwd, :string, public?: true
    attribute :model, :string, public?: true
    attribute :messages, {:array, PiEx.Chat.Message}, default: [], public?: true
    attribute :steering_queue, {:array, :string}, default: [], public?: true
    attribute :created_at, :utc_datetime_usec, default: &DateTime.utc_now/0, public?: true
  end

  actions do
    defaults [:read]

    create :start do
      accept [:system_prompt, :cwd, :model]
    end
  end
end
