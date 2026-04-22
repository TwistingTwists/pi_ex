defmodule PiEx.Events do
  @moduledoc "Centralized event dispatch via Registry."

  @registry PiEx.EventRegistry

  @doc "Subscribe the calling process to events for the given session_id."
  @spec subscribe(String.t()) :: {:ok, pid()} | {:error, term()}
  def subscribe(session_id) do
    Registry.register(@registry, session_id, [])
  end

  @doc "Subscribe a specific pid to events for the given session_id."
  @spec subscribe(String.t(), pid()) :: :ok
  def subscribe(session_id, pid) do
    # Registry requires the owning process to call register/3.
    # We spawn a lightweight relay process that registers and forwards events.
    {:ok, _} =
      Task.Supervisor.start_child(PiEx.TaskSupervisor, fn ->
        Registry.register(@registry, session_id, {:relay_to, pid})
        ref = Process.monitor(pid)

        relay_loop(ref, pid, session_id)
      end)

    :ok
  end

  defp relay_loop(ref, target, session_id) do
    receive do
      {:DOWN, ^ref, :process, ^target, _} ->
        :ok

      {:pi_ex, ^session_id, _event} = msg ->
        send(target, msg)
        relay_loop(ref, target, session_id)
    end
  end

  @doc "Broadcast an event to all subscribers of the given session_id."
  @spec broadcast(String.t(), map()) :: :ok
  def broadcast(session_id, event) do
    msg = {:pi_ex, session_id, event}

    Registry.dispatch(@registry, session_id, fn entries ->
      for {pid, value} <- entries do
        case value do
          {:relay_to, _target} -> send(pid, msg)
          _ -> send(pid, msg)
        end
      end
    end)
  end

  @doc "Broadcast an event and also call an optional callback."
  @spec broadcast(String.t(), map(), (map() -> any()) | nil) :: :ok
  def broadcast(session_id, event, nil), do: broadcast(session_id, event)

  def broadcast(session_id, event, on_event) when is_function(on_event, 1) do
    on_event.(event)
    broadcast(session_id, event)
  end
end
