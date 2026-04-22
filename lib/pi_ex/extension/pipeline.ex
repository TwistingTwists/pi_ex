defmodule PiEx.Extension.Pipeline do
  @moduledoc "Dispatches events through the extension chain."

  @type ext_entry :: {module(), term()}

  @doc "Initialize all extensions, returning {mod, state} tuples."
  @spec init([module() | {module(), map()}], map()) :: {:ok, [ext_entry()]} | {:error, term()}
  def init(extensions, _config \\ %{}) do
    results =
      Enum.reduce_while(extensions, {:ok, []}, fn ext_spec, {:ok, acc} ->
        {mod, config} = normalize(ext_spec)

        case mod.init(config) do
          {:ok, state} -> {:cont, {:ok, acc ++ [{mod, state}]}}
          {:error, reason} -> {:halt, {:error, {mod, reason}}}
        end
      end)

    results
  end

  @doc "Dispatch an event through all extensions in order."
  @spec dispatch([ext_entry()], PiEx.Extension.event_name(), map(), map()) ::
          {[ext_entry()], map()}
  def dispatch(ext_entries, event_name, payload, context) do
    Enum.reduce_while(ext_entries, {[], payload}, fn {mod, state}, {acc, payload} ->
      case mod.handle_event(event_name, payload, context, state) do
        {:ok, new_state} ->
          {:cont, {acc ++ [{mod, new_state}], payload}}

        {:mutate, changes, new_state} ->
          {:cont, {acc ++ [{mod, new_state}], Map.merge(payload, changes)}}

        {:block, reason, new_state} ->
          # Short-circuit: keep remaining entries unchanged
          remaining = ext_entries |> Enum.drop(length(acc) + 1)
          entries = acc ++ [{mod, new_state}] ++ remaining
          {:halt, {entries, Map.put(payload, :blocked, reason)}}
      end
    end)
  end

  @doc "Collect tools from all extensions that implement tools/0."
  @spec collect_tools([ext_entry()]) :: [module()]
  def collect_tools(ext_entries) do
    Enum.flat_map(ext_entries, fn {mod, _state} ->
      if function_exported?(mod, :tools, 0), do: mod.tools(), else: []
    end)
  end

  defp normalize({mod, config}) when is_atom(mod) and is_map(config), do: {mod, config}
  defp normalize(mod) when is_atom(mod), do: {mod, %{}}
end
