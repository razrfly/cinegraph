defmodule CinegraphWeb.Admin.QueuesLive do
  @moduledoc """
  Oban queue health dashboard at `/admin/queues`.

  Reads `Cinegraph.Health.Queues.snapshot/0` for per-queue state, surfaces
  PQS monitoring health from `Cinegraph.Metrics.PQSMonitoring`, and shows
  recent failures from `ObanReader.discards_for_queue/3`. Refreshes every
  30 seconds, mirroring `AdminHealthLive`'s polling pattern (no PubSub).

  Phase 1 of #880.
  """
  use CinegraphWeb, :admin_live_view

  alias Cinegraph.Health.{ObanReader, Queues}
  alias Cinegraph.Metrics.PQSMonitoring

  @refresh_interval 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_interval)

    {:ok,
     socket
     |> assign(:page_title, "Queues")
     |> assign_data()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, assign_data(socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign_data(socket, force: true)}
  end

  defp assign_data(socket, opts \\ []) do
    snapshot = safe_snapshot(opts)
    discards = safe_discards()
    pqs = safe_pqs_health()

    socket
    |> assign(:snapshot, snapshot)
    |> assign(:discards, discards)
    |> assign(:pqs, pqs)
    |> assign(:queue_concurrency, queue_concurrency_map())
    |> assign(:loaded_at, DateTime.utc_now())
  end

  defp safe_snapshot(opts) do
    Queues.snapshot(opts)
  rescue
    _ -> :error
  end

  defp safe_discards do
    one_hour_ago = DateTime.add(DateTime.utc_now(), -60 * 60)

    ObanReader.configured_queues()
    |> Enum.flat_map(fn q ->
      ObanReader.discards_for_queue([queue: q], one_hour_ago)
    end)
    |> Enum.sort_by(& &1.discarded_at, {:desc, DateTime})
    |> Enum.take(50)
  rescue
    _ -> :error
  end

  defp safe_pqs_health do
    %{
      indicators: PQSMonitoring.get_health_indicators(),
      coverage: PQSMonitoring.get_coverage_metrics(),
      freshness: PQSMonitoring.get_freshness_metrics(),
      performance: PQSMonitoring.get_performance_metrics()
    }
  rescue
    _ -> :error
  end

  defp queue_concurrency_map do
    Application.get_env(:cinegraph, Oban)[:queues]
    |> Enum.into(%{})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title="Queues"
      subtitle={"Oban queue health · refreshed at #{format_dt(@loaded_at)} UTC"}
    >
      <:actions>
        <button
          type="button"
          phx-click="refresh"
          class="text-sm text-gray-700 hover:text-gray-900 underline"
        >
          Refresh
        </button>
      </:actions>
    </.page_header>

    <%= if @snapshot == :error do %>
      <.section_card>
        <p class="text-sm text-red-700">
          Could not load queue snapshot. Check `Cinegraph.Health.Queues.snapshot/0` logs.
        </p>
      </.section_card>
    <% else %>
      <%!-- KPI strip --%>
      <div class="grid grid-cols-2 lg:grid-cols-4 gap-4 mb-6">
        <.kpi_card
          title="Available jobs"
          value={total_state(@snapshot.queues, :available)}
          accent={:blue}
          icon={:chart}
          subtitle="Across all queues"
        />
        <.kpi_card
          title="Executing"
          value={total_state(@snapshot.queues, :executing)}
          accent={:green}
          icon={:plug}
          subtitle="Currently running"
        />
        <.kpi_card
          title="Failures (1h)"
          value={@snapshot.total_failures_last_hour}
          accent={failures_accent(@snapshot.total_failures_last_hour)}
          icon={:chart}
        />
        <.kpi_card
          title="Queues"
          value={length(@snapshot.queues)}
          accent={:zinc}
          icon={:plug}
          subtitle="Configured"
        />
      </div>

      <%!-- Per-queue cards --%>
      <h2 class="text-lg font-semibold text-gray-900 mb-3">Per queue</h2>
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4 mb-6">
        <%= for q <- @snapshot.queues do %>
          <% concurrency = Map.get(@queue_concurrency, q.name, nil) %>
          <% utilization = utilization_pct(q.executing, concurrency) %>
          <.section_card>
            <div class="flex items-center justify-between mb-2">
              <h3 class="text-base font-semibold text-gray-900">
                <code>{q.name}</code>
                <span class="ml-2 text-xs text-gray-500 font-normal">
                  limit {concurrency || "—"}
                </span>
              </h3>
              <%= if (q.longest_running_seconds || 0) > 300 do %>
                <span class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-red-100 text-red-800">
                  longest: {format_seconds(q.longest_running_seconds)}
                </span>
              <% else %>
                <span :if={(q.longest_running_seconds || 0) > 0} class="text-xs text-gray-500">
                  longest: {format_seconds(q.longest_running_seconds)}
                </span>
              <% end %>
            </div>

            <%= if concurrency do %>
              <div class="mb-3">
                <.progress_bar
                  value={utilization}
                  color={utilization_color(utilization)}
                  show_label
                />
              </div>
            <% end %>

            <dl class="grid grid-cols-3 gap-2 text-sm">
              <div>
                <dt class="text-xs text-gray-500">Available</dt>
                <dd class="font-mono text-gray-900">{q.available || 0}</dd>
              </div>
              <div>
                <dt class="text-xs text-gray-500">Executing</dt>
                <dd class="font-mono text-gray-900">{q.executing || 0}</dd>
              </div>
              <div>
                <dt class="text-xs text-gray-500">Scheduled</dt>
                <dd class="font-mono text-gray-900">{q.scheduled || 0}</dd>
              </div>
              <div>
                <dt class="text-xs text-gray-500">Retryable</dt>
                <dd class={"font-mono #{count_color(q.retryable)}"}>{q.retryable || 0}</dd>
              </div>
              <div>
                <dt class="text-xs text-gray-500">Discarded</dt>
                <dd class={"font-mono #{count_color(q.discarded)}"}>{q.discarded || 0}</dd>
              </div>
              <div>
                <dt class="text-xs text-gray-500">Failures (1h)</dt>
                <dd class={"font-mono #{count_color(q.failures_last_hour)}"}>
                  {q.failures_last_hour || 0}
                </dd>
              </div>
            </dl>
          </.section_card>
        <% end %>
      </div>
    <% end %>

    <%!-- Side widgets --%>
    <div class="grid grid-cols-1 lg:grid-cols-2 gap-4 mb-6">
      <.section_card title="PQS health">
        <%= if @pqs == :error do %>
          <p class="text-sm text-gray-500">PQS monitoring offline.</p>
        <% else %>
          <% indicators = @pqs.indicators %>
          <% coverage = @pqs.coverage %>
          <% freshness = @pqs.freshness %>
          <div class="mb-3">
            <span class={"inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium #{pqs_status_class(indicators.overall_status)}"}>
              {String.capitalize(to_string(indicators.overall_status))}
            </span>
            <span class="ml-2 text-xs text-gray-500">
              last batch: {format_dt(indicators.last_successful_batch)}
            </span>
          </div>
          <dl class="grid grid-cols-2 gap-3 text-sm">
            <div>
              <dt class="text-xs text-gray-500">Coverage</dt>
              <dd class="font-mono text-gray-900">
                {format_pct(coverage.coverage_percent)}
              </dd>
              <dd class="text-xs text-gray-500">
                {format_count(coverage.people_with_pqs)} / {format_count(coverage.eligible_people)}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500">Freshness</dt>
              <dd class="font-mono text-gray-900">{format_pct(freshness.fresh_percent)}</dd>
              <dd class="text-xs text-gray-500">
                avg age {format_count(freshness.average_age_days)}d
              </dd>
            </div>
          </dl>
          <div :if={indicators.system_alerts != []} class="mt-3 text-xs">
            <p class="text-gray-500 font-medium mb-1">Alerts</p>
            <ul class="list-disc list-inside text-amber-700">
              <li :for={alert <- indicators.system_alerts}>{alert}</li>
            </ul>
          </div>
        <% end %>
      </.section_card>

      <.section_card title="Festival inference monitor">
        <p class="text-sm text-gray-500">
          {festival_monitor_status()}
        </p>
        <p class="mt-2 text-xs text-gray-500">
          Auto-queues <code>FestivalPersonInferenceWorker</code>
          when <code>FestivalDiscoveryWorker</code>
          jobs complete. Activity is
          visible via the festival-discovery queue counters above and via <a
            href="/admin/scheduled/festival_person_inference_worker"
            class="text-blue-700 hover:text-blue-900 underline"
          >/admin/scheduled/festival_person_inference_worker</a>.
        </p>
      </.section_card>
    </div>

    <%!-- Recent failures --%>
    <.section_card title="Failures (last 1h, all queues)">
      <%= cond do %>
        <% @discards == :error -> %>
          <p class="text-sm text-red-700">
            Could not load discards. Check ObanReader logs.
          </p>
        <% Enum.empty?(@discards) -> %>
          <p class="text-sm text-gray-500">No failures in the last hour. ✓</p>
        <% true -> %>
          <ul class="divide-y divide-gray-100">
            <%= for d <- @discards do %>
              <li class="py-3">
                <div class="flex items-baseline justify-between gap-4">
                  <div class="text-xs font-mono text-gray-700">
                    {short_worker_name(d.worker)}
                  </div>
                  <div class="text-xs text-gray-500">
                    job ##{d.id} · attempt {d.attempt} · {format_dt(d.discarded_at)}
                  </div>
                </div>
                <div class="mt-1 text-xs text-red-700 font-mono break-words">
                  {format_error(d.last_error)}
                </div>
              </li>
            <% end %>
          </ul>
      <% end %>
    </.section_card>
    """
  end

  defp total_state(queues, key) when is_list(queues) do
    Enum.reduce(queues, 0, &((Map.get(&1, key) || 0) + &2))
  end

  defp total_state(_, _), do: 0

  defp failures_accent(0), do: :green
  defp failures_accent(n) when is_integer(n) and n < 10, do: :yellow
  defp failures_accent(_), do: :red

  defp utilization_pct(_, nil), do: 0

  defp utilization_pct(executing, concurrency) when is_integer(concurrency) and concurrency > 0 do
    min(100, round((executing || 0) / concurrency * 100))
  end

  defp utilization_pct(_, _), do: 0

  defp utilization_color(p) when p < 50, do: :blue
  defp utilization_color(p) when p < 90, do: :yellow
  defp utilization_color(_), do: :red

  defp count_color(n) when is_integer(n) and n > 0, do: "text-red-700 font-medium"
  defp count_color(_), do: "text-gray-900"

  defp format_seconds(s) when is_integer(s) and s >= 3600,
    do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"

  defp format_seconds(s) when is_integer(s) and s >= 60, do: "#{div(s, 60)}m #{rem(s, 60)}s"
  defp format_seconds(s) when is_integer(s) and s > 0, do: "#{s}s"
  defp format_seconds(_), do: "—"

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_dt(_), do: "—"

  defp format_count(nil), do: "0"
  defp format_count(n) when is_integer(n), do: Integer.to_string(n)
  defp format_count(n) when is_float(n), do: Integer.to_string(round(n))
  defp format_count(_), do: "—"

  defp format_pct(nil), do: "—"
  defp format_pct(p) when is_number(p), do: "#{:erlang.float_to_binary(p * 1.0, decimals: 1)}%"
  defp format_pct(_), do: "—"

  defp format_error(nil), do: "(no error message)"
  defp format_error(err) when is_binary(err), do: String.slice(err, 0, 300)
  defp format_error(err), do: inspect(err) |> String.slice(0, 300)

  defp short_worker_name(nil), do: "unknown"

  defp short_worker_name(worker) when is_binary(worker) do
    worker
    |> String.split(".")
    |> List.last()
  end

  defp short_worker_name(_), do: "unknown"

  defp pqs_status_class(:healthy), do: "bg-green-100 text-green-800"
  defp pqs_status_class(:warning), do: "bg-amber-100 text-amber-800"
  defp pqs_status_class(:critical), do: "bg-red-100 text-red-800"
  defp pqs_status_class(_), do: "bg-gray-100 text-gray-700"

  # Read FestivalInferenceMonitor's GenServer state if it's running.
  # Wrapped in try/rescue + try/catch so the page never crashes when the
  # monitor is offline (e.g., in tests).
  defp festival_monitor_status do
    case GenServer.whereis(Cinegraph.ObanPlugins.FestivalInferenceMonitor) do
      nil ->
        "Monitor offline."

      pid ->
        try do
          state = :sys.get_state(pid, 1000)
          last = state[:last_check] || state.last_check

          case last do
            nil -> "Monitor running. No checks completed yet."
            %DateTime{} = dt -> "Monitor running. Last check #{format_dt(dt)} UTC."
            _ -> "Monitor running."
          end
        rescue
          _ -> "Monitor running (state read failed)."
        catch
          _, _ -> "Monitor running (state read failed)."
        end
    end
  rescue
    _ -> "Monitor status unknown."
  end
end
