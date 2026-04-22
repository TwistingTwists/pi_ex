defmodule PiEx.Chat.ToolCall do
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :id, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :arguments, :map, default: %{}, public?: true
  end

  actions do
    default_accept :*
    defaults [:read, create: :*]
  end
end
