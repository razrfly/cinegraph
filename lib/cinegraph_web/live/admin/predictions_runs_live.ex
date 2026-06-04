defmodule CinegraphWeb.Admin.PredictionsRunsLive do
  @moduledoc """
  `/admin/predictions/runs` (#1065 Session 2, Phase 4) — visibility into prediction matrix/promote
  runs: the active run's live progress + cell grid, recent-run history, and a timing report.

  The `prediction_runs` row is the source of truth (counters advance live via `RunReporter`); this
  view **polls** it every #{2_500}ms as the reliable floor and also subscribes to the
  `"predictions:runs"` PubSub topic to refresh instantly when a run is on the server node. A
  standalone `mix predictions.matrix` is a different BEAM node, so polling — not PubSub — is what
  surfaces it. Read-only; [Stop]/[Logs] need same-node execution and are deferred.
  """
  use CinegraphWeb, :admin_live_view

  alias Cinegraph.Predictions.{RunReporter, Runs}

  @refresh_ms 2_500

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :refresh, @refresh_ms)
      Phoenix.PubSub.subscribe(Cinegraph.PubSub, RunReporter.topic())
    end

    {:ok, socket |> assign(:page_title, "Prediction Runs") |> load()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, load(socket)}
  end

  # A run wrote progress on this node — refresh now instead of waiting for the next poll.
  def handle_info({:run_progress, _run_id}, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("select_run", %{"id" => run_id}, socket) do
    {:noreply, load(socket, run_id)}
  end

  defp load(socket, selected \\ :keep) do
    active = Runs.active()
    recent = Runs.list_recent(20)

    selected_id =
      case selected do
        :keep -> socket.assigns[:selected_id] || default_selected(active, recent)
        id -> id
      end

    socket
    |> assign(:active, active)
    |> assign(:recent, recent)
    |> assign(:selected_id, selected_id)
    |> assign(:grid, selected_id && Runs.cell_grid(selected_id))
    |> assign(:timing, Runs.timing_report())
  end

  defp default_selected(active, recent) do
    cond do
      active != [] -> hd(active).run.run_id
      recent != [] -> hd(recent).run.run_id
      true -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title="Prediction Runs"
      subtitle={"#{length(@active)} active · #{length(@recent)} recent — matrix & promote runs, live progress + timing."}
    />

    <%= if @active == [] do %>
      <.section_card>
        <p class="text-sm text-gray-500">No run in progress. Recent runs and timing below.</p>
      </.section_card>
    <% else %>
      <div :for={a <- @active} class="mb-6">
        <.section_card>
          <div class="flex items-center justify-between mb-2">
            <div class="flex items-center gap-2">
              <span class={[
                "inline-flex h-2.5 w-2.5 rounded-full",
                if(a.stale, do: "bg-amber-400", else: "bg-green-500 animate-pulse")
              ]}>
              </span>
              <span class="font-semibold">{a.run.kind}</span>
              <code class="text-xs text-gray-500">{a.run.run_id}</code>
              <span :if={a.stale} class="text-xs text-amber-700">stale (no heartbeat)</span>
            </div>
            <div class="text-sm text-gray-600">
              ETA {dur(a.eta_ms)} · {rate(a.throughput_per_min)}
            </div>
          </div>

          <.progress_bar value={a.pct} color={if(a.failed > 0, do: :amber, else: :blue)} show_label />

          <div class="mt-2 text-sm text-gray-600">
            {a.done}/{a.total} cells ({a.pct}%) · <span class="text-green-700">✓ {a.ok}</span>
            · <span class="text-red-700">⚠ {a.failed}</span>
            ·
            now: <code class="text-xs">{a.run.current_cell || "—"}</code>
          </div>
        </.section_card>
      </div>
    <% end %>

    <.section_card title="Cell grid">
      <%= if @grid && @grid.rows != [] do %>
        <div class="overflow-x-auto">
          <table class="min-w-full text-sm">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-3 py-2 text-left text-xs font-medium text-gray-500 uppercase">List</th>
                <th
                  :for={{s, b} <- @grid.columns}
                  class="px-3 py-2 text-center text-xs font-medium text-gray-500"
                >
                  {s}/{b}
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :for={row <- @grid.rows} class="hover:bg-gray-50">
                <td class="px-3 py-2 font-medium text-gray-700">{row.source_key}</td>
                <td :for={col <- @grid.columns} class="px-3 py-2 text-center">
                  {grid_icon(row.cells[col])}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p class="mt-2 text-xs text-gray-400">legend: ✓ ok · ◐ running · · pending · ⚠ failed</p>
      <% else %>
        <p class="text-sm text-gray-500">
          Select a matrix run below to see its cell grid (promote runs have no grid).
        </p>
      <% end %>
    </.section_card>

    <.section_card title="Recent runs">
      <div class="overflow-x-auto">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">When</th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">Kind</th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">Status</th>
              <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">Cells</th>
              <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                ok/fail
              </th>
              <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">Wall</th>
              <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                Avg/cell
              </th>
            </tr>
          </thead>
          <tbody class="bg-white divide-y divide-gray-100">
            <tr
              :for={r <- @recent}
              class={["hover:bg-gray-50 cursor-pointer", @selected_id == r.run.run_id && "bg-blue-50"]}
              phx-click="select_run"
              phx-value-id={r.run.run_id}
            >
              <td class="px-4 py-2 text-sm text-gray-600">{when_label(r.run.started_at)}</td>
              <td class="px-4 py-2 text-sm">{r.run.kind}</td>
              <td class="px-4 py-2 text-sm">{run_status_badge(r)}</td>
              <td class="px-4 py-2 text-sm text-right">{r.total || "—"}</td>
              <td class="px-4 py-2 text-sm text-right">{r.ok}/{r.failed}</td>
              <td class="px-4 py-2 text-sm text-right">{dur(r.wall_ms)}</td>
              <td class="px-4 py-2 text-sm text-right">{dur(r.avg_cell_ms)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </.section_card>

    <.section_card title="Timing report">
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <div>
          <h4 class="text-xs font-medium text-gray-500 uppercase mb-2">Avg duration by shape</h4>
          <table class="min-w-full text-sm">
            <tbody class="divide-y divide-gray-100">
              <tr :for={s <- @timing.by_shape}>
                <td class="py-1 text-gray-700">{s.strategy}/{s.bucket}</td>
                <td class="py-1 text-right text-gray-600">{dur(ms_int(s.avg_ms))}</td>
                <td class="py-1 text-right text-xs text-gray-400">n={s.n}</td>
              </tr>
              <tr :if={@timing.by_shape == []}>
                <td class="py-1 text-gray-400">no timing history yet</td>
              </tr>
            </tbody>
          </table>

          <p :if={@timing.cost_model} class="mt-3 text-sm text-gray-600">
            cost model: duration ≈ <strong>{Float.round(@timing.cost_model.k, 4)}</strong>
            ms/movie-score · r² {Float.round(@timing.cost_model.r2, 2)} · ±{round(
              @timing.cost_model.rel_err * 100
            )}% · n={@timing.cost_model.n}
          </p>
        </div>

        <div>
          <h4 class="text-xs font-medium text-gray-500 uppercase mb-2">Slowest cells</h4>
          <table class="min-w-full text-sm">
            <tbody class="divide-y divide-gray-100">
              <tr :for={c <- @timing.slowest}>
                <td class="py-1 text-gray-700">{c.source_key}/{c.strategy}/{c.bucket}</td>
                <td class="py-1 text-right text-gray-600">{dur(c.duration_ms)}</td>
                <td class="py-1 text-right text-xs text-gray-400">{c.n_evaluated} scored</td>
              </tr>
              <tr :if={@timing.slowest == []}>
                <td class="py-1 text-gray-400">no timing history yet</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </.section_card>
    """
  end

  # ── view helpers ──────────────────────────────────────────────────────────────────

  defp grid_icon(:ok), do: "✓"
  defp grid_icon(:failed), do: "⚠"
  defp grid_icon(:running), do: "◐"
  defp grid_icon(:pending), do: "·"
  defp grid_icon(_), do: ""

  defp run_status_badge(%{run: %{status: status}, stale: stale}) do
    {label, classes} =
      cond do
        stale -> {"stale", "bg-amber-100 text-amber-800"}
        status == "running" -> {"running", "bg-blue-100 text-blue-800"}
        status == "completed" -> {"completed", "bg-green-100 text-green-800"}
        status == "failed" -> {"failed", "bg-red-100 text-red-800"}
        true -> {status, "bg-gray-100 text-gray-700"}
      end

    assigns = %{label: label, classes: classes}

    ~H"""
    <span class={["inline-flex rounded-full px-2 py-0.5 text-xs font-medium", @classes]}>
      {@label}
    </span>
    """
  end

  defp dur(nil), do: "—"
  defp dur(ms) when ms < 1_000, do: "#{ms}ms"
  defp dur(ms) when ms < 60_000, do: "#{round(ms / 1000)}s"
  defp dur(ms), do: "#{Float.round(ms / 60_000, 1)}m"

  defp rate(nil), do: "—"
  defp rate(per_min), do: "#{per_min}/min"

  defp ms_int(nil), do: nil
  defp ms_int(%Decimal{} = d), do: Decimal.round(d) |> Decimal.to_integer()
  defp ms_int(n) when is_float(n), do: round(n)
  defp ms_int(n), do: n

  defp when_label(nil), do: "—"
  defp when_label(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d %H:%M")
end
