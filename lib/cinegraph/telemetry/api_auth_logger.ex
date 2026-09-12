defmodule Cinegraph.Telemetry.ApiAuthLogger do
  @moduledoc "Records catalog authentication outcomes and field counts without credentials."
  use GenServer
  require Logger

  @events [[:cinegraph, :api_auth, :stop], [:cinegraph, :api_auth, :catalog_field]]
  @metadata [:outcome, :auth_kind, :client_id, :key_id, :client_slug]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # A killed process may not run terminate/2; replace its stale handler.
    :telemetry.detach(__MODULE__)
    :ok = :telemetry.attach_many(__MODULE__, @events, &__MODULE__.handle_event/4, nil)
    {:ok, nil}
  end

  @impl true
  def terminate(_reason, _state), do: :telemetry.detach(__MODULE__)

  def handle_event(event, measurements, metadata, _config) do
    record =
      metadata
      |> Map.take(@metadata)
      |> Map.put(:event, Enum.join(event, "."))
      |> Map.merge(Map.take(measurements, [:count, :request_cost]))

    Logger.info(fn -> "catalog_api " <> Jason.encode!(record) end)
  end
end
