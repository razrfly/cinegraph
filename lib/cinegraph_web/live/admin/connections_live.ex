defmodule CinegraphWeb.Admin.ConnectionsLive do
  @moduledoc """
  Admin view of shared-Postgres connection health (`/admin/connections`, #1018
  Session 5).

  Polls `Cinegraph.Database.Monitoring.snapshot/0` (a cheap `pg_stat_activity`
  query) every 10s and shows total backends vs `max_connections`, per-database
  counts (cinegraph reads its bounded PgBouncer pool, ~16–25), and any
  long-running queries. The `ConnectionMonitorWorker` does the same check every
  5 min and alerts via logs/Honeybadger.
  """
  use CinegraphWeb, :admin_live_view

  alias Cinegraph.Database.Monitoring

  @refresh_ms 10_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    {:ok,
     socket
     |> assign(:page_title, "Connections")
     |> assign_snapshot()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign_snapshot(socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, assign_snapshot(socket)}

  defp assign_snapshot(socket) do
    snap =
      try do
        Monitoring.snapshot()
      rescue
        e -> {:error, Exception.message(e)}
      end

    socket
    |> assign(:snapshot, snap)
    |> assign(:loaded_at, DateTime.utc_now())
  end

  @impl true
  def render(%{snapshot: {:error, msg}} = assigns) do
    assigns = assign(assigns, :msg, msg)

    ~H"""
    <div class="p-6">
      <h1 class="text-xl font-semibold mb-4">Database connections</h1>
      <div class="rounded bg-red-50 text-red-700 p-4">Snapshot failed: {@msg}</div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="p-6 space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-xl font-semibold">Database connections</h1>
        <button phx-click="refresh" class="text-sm px-3 py-1 rounded border hover:bg-gray-50">
          Refresh
        </button>
      </div>

      <div class="flex items-center gap-4">
        <span class={"px-3 py-1 rounded-full text-sm font-medium #{status_class(@snapshot.status)}"}>
          {String.upcase(to_string(@snapshot.status))}
        </span>
        <div class="text-2xl font-semibold">
          {@snapshot.total_backends}<span class="text-gray-400">/{@snapshot.max_connections}</span>
          <span class="text-base font-normal text-gray-500">backends ({@snapshot.usage_pct}%)</span>
        </div>
      </div>

      <div :if={@snapshot.warnings != []} class="rounded bg-amber-50 text-amber-800 p-3 text-sm">
        <ul class="list-disc list-inside">
          <li :for={w <- @snapshot.warnings}>{w}</li>
        </ul>
      </div>

      <div>
        <h2 class="font-medium mb-2">By database</h2>
        <table class="min-w-[24rem] text-sm">
          <thead>
            <tr class="text-left text-gray-500 border-b">
              <th class="py-1 pr-8">Database</th>
              <th class="py-1">Backends</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @snapshot.by_database} class="border-b last:border-0">
              <td class="py-1 pr-8 font-mono">{row.datname}</td>
              <td class="py-1">{row.count}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div>
        <h2 class="font-medium mb-2">
          Long-running active queries (&gt; 5 min)
          <span class="text-gray-500 font-normal">({length(@snapshot.long_running)})</span>
        </h2>
        <p :if={@snapshot.long_running == []} class="text-sm text-gray-500">None.</p>
        <table :if={@snapshot.long_running != []} class="w-full text-sm">
          <thead>
            <tr class="text-left text-gray-500 border-b">
              <th class="py-1 pr-4">pid</th>
              <th class="py-1 pr-4">db</th>
              <th class="py-1 pr-4">age (s)</th>
              <th class="py-1">query</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={q <- @snapshot.long_running} class="border-b last:border-0 align-top">
              <td class="py-1 pr-4 font-mono">{q.pid}</td>
              <td class="py-1 pr-4">{q.datname}</td>
              <td class="py-1 pr-4">{q.duration_s}</td>
              <td class="py-1 font-mono text-xs truncate max-w-xl">{q.query}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <p class="text-xs text-gray-400">
        Updated {Calendar.strftime(@loaded_at, "%H:%M:%S")} UTC · polls every 10s ·
        PgBouncer <code>SHOW POOLS</code> is host-only (see MAINTENANCE.md)
      </p>
    </div>
    """
  end

  defp status_class(:crit), do: "bg-red-100 text-red-800"
  defp status_class(:warn), do: "bg-amber-100 text-amber-800"
  defp status_class(_), do: "bg-green-100 text-green-800"
end
