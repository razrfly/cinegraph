defmodule CinegraphWeb.Admin.HomeostasisLive do
  @moduledoc """
  `/admin/homeostasis` (#1108 §10c) — the surface-area + freshness dashboard.

  Renders `Cinegraph.Health.SurfaceArea.cached_report/1` (per-source terminal
  state), the freshness due-counts, the read-through spend panel (#1108 §4), and
  the "viewed-but-stale" canary. Mirrors `AdminHealthLive.Show`: synchronous
  cache-backed load + 30s auto-refresh + a force "Recompute" button.
  """
  use CinegraphWeb, :admin_live_view

  import Ecto.Query

  alias Cinegraph.Freshness
  alias Cinegraph.Freshness.SpendGuard
  alias Cinegraph.Health.{ObanReader, SurfaceArea}
  alias Cinegraph.Repo

  @refresh_interval 30_000
  @freshness_sources ~w(tmdb_details watch_providers omdb imdb_id tmdb_person)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Homeostasis")
     |> load(force: false)
     |> maybe_schedule_refresh()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, socket |> load(force: false) |> maybe_schedule_refresh()}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load(socket, force: true)}
  end

  # ===== load =====

  defp load(socket, opts) do
    force? = Keyword.get(opts, :force, false)

    report = safe(fn -> SurfaceArea.cached_report(bypass_cache: force?) end)
    due = safe(fn -> due_counts() end)
    spend = safe(fn -> spend_snapshot() end)
    canary = safe(fn -> viewed_but_stale_count() end)

    socket
    |> assign(:report, report)
    |> assign(:due, ok(due, %{}))
    |> assign(:spend, ok(spend, nil))
    |> assign(:canary, ok(canary, nil))
    |> assign(:loaded_at, DateTime.utc_now())
    |> assign(:loading_error, error_msg(report))
  end

  defp due_counts do
    Map.new(@freshness_sources, fn src -> {src, Freshness.due_count(src)} end)
  end

  defp spend_snapshot do
    since = start_of_utc_day()

    depths =
      ObanReader.counts_by_queue_and_state(
        [:tmdb, :omdb, :maintenance],
        [:available, :scheduled, :executing, :retryable]
      )

    %{
      enabled: SpendGuard.enabled?(),
      caps: Application.get_env(:cinegraph, :read_through_daily_caps, %{}),
      tmdb_today: ObanReader.count_completed_since(since, :tmdb),
      omdb_today: ObanReader.count_completed_since(since, :omdb),
      depths: Map.new(depths, fn {q, states} -> {q, states |> Map.values() |> Enum.sum()} end)
    }
  end

  # viewed-but-stale (#1010 §10): read-through evaluated it recently but it's still due.
  defp viewed_but_stale_count do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -24 * 3600, :second)

    from(r in "data_refreshes",
      where:
        not is_nil(r.last_checked_at) and r.last_checked_at > ^cutoff and
          not is_nil(r.stale_after) and r.stale_after < ^now and r.status != "ineligible",
      select: count(r.id)
    )
    |> Repo.replica().one()
  end

  defp start_of_utc_day do
    DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  defp safe(fun) do
    fun.()
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp ok({:error, _}, default), do: default
  defp ok(v, _default), do: v

  defp error_msg({:error, msg}), do: msg
  defp error_msg(_), do: nil

  defp maybe_schedule_refresh(socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_interval)
    socket
  end

  # ===== render =====

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">Homeostasis</h1>
          <p class="text-sm text-gray-500">
            Surface area · freshness · read-through spend
            <span :if={@loaded_at}>· loaded {Calendar.strftime(@loaded_at, "%H:%M:%S UTC")}</span>
          </p>
        </div>
        <button
          phx-click="refresh"
          class="px-3 py-2 text-sm bg-gray-800 text-white rounded hover:bg-gray-700"
        >
          Recompute
        </button>
      </div>

      <div :if={@loading_error} class="p-3 bg-red-50 text-red-700 rounded text-sm">
        Report error: {@loading_error}
      </div>

      <.spend_panel :if={@spend} spend={@spend} canary={@canary} />

      <div :if={is_map(@report)} class="overflow-x-auto border rounded">
        <table class="min-w-full text-sm">
          <thead class="bg-gray-50 text-left">
            <tr>
              <th class="px-3 py-2">Source</th>
              <th class="px-3 py-2">Kind</th>
              <th class="px-3 py-2 text-right">Terminal</th>
              <th class="px-3 py-2 text-right">Fetched</th>
              <th class="px-3 py-2 text-right">Source-absent</th>
              <th class="px-3 py-2 text-right">Needs fetch</th>
              <th class="px-3 py-2 text-right">Due now</th>
              <th class="px-3 py-2">Note</th>
            </tr>
          </thead>
          <tbody class="divide-y">
            <tr :for={s <- @report.sources} class="hover:bg-gray-50">
              <td class="px-3 py-2 font-mono">{s.source}</td>
              <td class="px-3 py-2 text-gray-500">{s.kind}</td>
              <td class="px-3 py-2 text-right font-semibold">{pct(s.terminal_pct)}</td>
              <td class="px-3 py-2 text-right">{num(s.fetched)}</td>
              <td class="px-3 py-2 text-right">{num(s.source_absent)}</td>
              <td class="px-3 py-2 text-right">{num(s.needs_fetch)}</td>
              <td class="px-3 py-2 text-right">{num(Map.get(@due, s.source))}</td>
              <td class="px-3 py-2 text-gray-400 text-xs max-w-md truncate" title={s.note}>
                {s.note}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp spend_panel(assigns) do
    ~H"""
    <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
      <div class="p-4 border rounded">
        <div class="text-xs text-gray-500 uppercase">Read-through</div>
        <div class={["text-lg font-bold", (@spend.enabled && "text-green-600") || "text-gray-400"]}>
          {(@spend.enabled && "ON") || "OFF"}
        </div>
        <div class="text-xs text-gray-500">
          viewed-but-stale: <span class="font-mono">{num(@canary) || "—"}</span>
        </div>
      </div>
      <div class="p-4 border rounded">
        <div class="text-xs text-gray-500 uppercase">TMDb spend (today)</div>
        <div class="text-lg font-bold font-mono">
          {num(@spend.tmdb_today)} / {num(Map.get(@spend.caps, :tmdb))}
        </div>
        <div class="text-xs text-gray-500">queue depth: {num(Map.get(@spend.depths, :tmdb))}</div>
      </div>
      <div class="p-4 border rounded">
        <div class="text-xs text-gray-500 uppercase">OMDb spend (today)</div>
        <div class="text-lg font-bold font-mono">
          {num(@spend.omdb_today)} / {num(Map.get(@spend.caps, :omdb))}
        </div>
        <div class="text-xs text-gray-500">queue depth: {num(Map.get(@spend.depths, :omdb))}</div>
      </div>
    </div>
    """
  end

  defp pct(nil), do: "—"
  defp pct(n) when is_number(n), do: "#{n}%"

  defp num(nil), do: "—"
  defp num(n) when is_integer(n), do: Number.Delimit.number_to_delimited(n, precision: 0)
  defp num(n), do: to_string(n)
end
