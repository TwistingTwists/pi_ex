defmodule PiEx.Chat.SessionEntry do
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :id, :string, allow_nil?: false, public?: true
    attribute :parent_id, :string, public?: true

    attribute :type, :atom do
      constraints one_of: [:message, :model_change, :label, :custom]
      allow_nil? false
      public? true
    end

    attribute :data, :map, default: %{}, public?: true
    attribute :timestamp, :utc_datetime_usec, default: &DateTime.utc_now/0, public?: true
  end

  actions do
    default_accept :*
    defaults [:read, create: :*]
  end
end
