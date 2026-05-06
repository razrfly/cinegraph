defmodule CinegraphWeb.AdminDashboardLive do
  @moduledoc """
  Cinegraph admin home page (`/admin`).

  Renders 5 live KPI tiles fed from `Cinegraph.Health.*` plus a nav grid
  linking to every admin LiveView. Refreshes every 30 seconds, mirroring
  `AdminHealthLive`'s polling pattern (no PubSub).

  Phase 1 of #880.
  """
  use CinegraphWeb, :admin_live_view

  alias Cinegraph.Health.{Activity, Completeness, Facade, Queues}

  @refresh_interval 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_interval)

    {:ok,
     socket
     |> assign(:page_title, "Admin")
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
    socket
    |> assign(:verdict, safe_verdict(opts))
    |> assign(:activity, safe_activity())
    |> assign(:queues, safe_queues(opts))
    |> assign(:completeness_history, safe_history())
    |> assign(:loaded_at, DateTime.utc_now())
  end

  defp safe_verdict(opts) do
    Facade.compute_full_verdict(opts)
  rescue
    _ -> :error
  end

  defp safe_activity do
    Activity.today()
  rescue
    _ -> :error
  end

  defp safe_queues(opts) do
    Queues.snapshot(opts)
  rescue
    _ -> :error
  end

  defp safe_history do
    Completeness.history(30)
  rescue
    _ -> :error
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title="Cinegraph admin"
      subtitle={"Last refreshed at #{format_dt(@loaded_at)} UTC · auto-refresh every 30s"}
    >
      <:actions>
        <.link
          navigate={~p"/admin/health"}
          class="text-sm font-medium text-blue-600 hover:text-blue-800"
        >
          Open homeostasis dashboard →
        </.link>
        <button
          type="button"
          phx-click="refresh"
          class="text-sm text-gray-700 hover:text-gray-900 underline"
        >
          Refresh
        </button>
      </:actions>
    </.page_header>

    <%!-- Live KPI tiles --%>
    <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-5 gap-4 mb-8">
      <.link navigate={~p"/admin/health"} class="block">
        <.kpi_card
          title="Verdict"
          value={verdict_label(@verdict)}
          accent={verdict_accent(@verdict)}
          subtitle={verdict_subtitle(@verdict)}
        />
      </.link>

      <.link navigate={~p"/admin/queues"} class="block">
        <.kpi_card
          title="Queue depth"
          value={queue_total_value(@queues)}
          accent={:blue}
          subtitle={queue_failures_subtitle(@queues)}
        />
      </.link>

      <.link navigate={~p"/admin/jobs"} class="block">
        <.kpi_card
          title="Today"
          value={today_value(@activity)}
          accent={:green}
          subtitle={today_subtitle(@activity)}
        />
      </.link>

      <.link navigate={~p"/admin/health"} class="block">
        <.kpi_card
          title="Coverage"
          value={completeness_value(@completeness_history)}
          accent={completeness_accent(@completeness_history)}
          subtitle={completeness_subtitle(@completeness_history)}
        />
      </.link>

      <.link navigate={~p"/admin/health"} class="block">
        <.kpi_card
          title="Alerts"
          value={alert_count(@verdict)}
          accent={alert_accent(@verdict)}
          subtitle={top_alert_label(@verdict)}
        />
      </.link>
    </div>

    <%!-- Nav grid (preserved from Phase 0, expanded with new routes) --%>
    <%= for section <- sections() do %>
      <.section_heading title={section.title} description={section.description} />
      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3 mb-8">
        <%= for card <- section.cards do %>
          <.link
            navigate={card.path}
            class="group block rounded-lg border border-gray-200 bg-white p-5 shadow-sm transition-shadow hover:shadow-md"
          >
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <div class="text-base font-semibold text-gray-900 group-hover:text-blue-600">
                  {card.title}
                </div>
                <p class="mt-1 text-sm text-gray-600">{card.description}</p>
              </div>
              <span class="text-gray-400 group-hover:text-blue-600 shrink-0" aria-hidden="true">
                →
              </span>
            </div>
            <div class="mt-3 text-xs font-mono text-gray-400">{card.path}</div>
          </.link>
        <% end %>
      </div>
    <% end %>
    """
  end

  # =========================================================================
  # KPI helpers
  # =========================================================================

  defp verdict_label(:error), do: "—"
  defp verdict_label(%{status: status}), do: status |> to_string() |> String.upcase()
  defp verdict_label(_), do: "—"

  defp verdict_accent(:error), do: :zinc
  defp verdict_accent(%{status: :green}), do: :green
  defp verdict_accent(%{status: :amber}), do: :amber
  defp verdict_accent(%{status: :red}), do: :red
  defp verdict_accent(_), do: :zinc

  defp verdict_subtitle(:error), do: "Verdict unavailable"

  defp verdict_subtitle(%{domains: domains}) when is_map(domains) do
    green =
      domains
      |> Map.values()
      |> Enum.count(&(&1.status == :green))

    "#{green}/#{map_size(domains)} domains green"
  end

  defp verdict_subtitle(_), do: nil

  defp queue_total_value(:error), do: "—"

  defp queue_total_value(%{queues: queues}) when is_list(queues) do
    queues
    |> Enum.reduce(0, &((&1.available || 0) + &2))
    |> Integer.to_string()
  end

  defp queue_total_value(_), do: "—"

  defp queue_failures_subtitle(:error), do: nil

  defp queue_failures_subtitle(%{total_failures_last_hour: 0}), do: "No failures (1h)"

  defp queue_failures_subtitle(%{total_failures_last_hour: n}) when is_integer(n),
    do: "#{n} failure#{if n == 1, do: "", else: "s"} (1h)"

  defp queue_failures_subtitle(_), do: nil

  defp today_value(:error), do: "—"

  defp today_value(%{movies_added: m, people_added: p}) when is_integer(m) and is_integer(p) do
    Integer.to_string(m + p)
  end

  defp today_value(_), do: "—"

  defp today_subtitle(:error), do: nil

  defp today_subtitle(%{movies_added: m, people_added: p}) when is_integer(m) and is_integer(p) do
    "#{m} films · #{p} people"
  end

  defp today_subtitle(_), do: nil

  defp completeness_value(:error), do: "—"
  defp completeness_value([]), do: "—"

  defp completeness_value(history) when is_list(history) do
    case List.last(history) do
      %{payload: %{"overall_completeness_pct" => pct}} when is_number(pct) ->
        "#{:erlang.float_to_binary(pct * 1.0, decimals: 1)}%"

      _ ->
        "—"
    end
  end

  defp completeness_value(_), do: "—"

  defp completeness_accent(:error), do: :zinc

  defp completeness_accent(history) when is_list(history) and length(history) >= 2 do
    pcts = pcts_from_history(history)

    if pcts != [] and List.last(pcts) >= 95.0, do: :green, else: :blue
  end

  defp completeness_accent(_), do: :blue

  defp completeness_subtitle(history) when is_list(history) and length(history) >= 8 do
    pcts = pcts_from_history(history)

    case {Enum.at(pcts, -8), List.last(pcts)} do
      {a, b} when is_number(a) and is_number(b) ->
        delta = b - a

        cond do
          delta > 0.05 ->
            "▲ #{:erlang.float_to_binary(delta, decimals: 2)} pts (7d)"

          delta < -0.05 ->
            "▼ #{:erlang.float_to_binary(abs(delta), decimals: 2)} pts (7d)"

          true ->
            "flat (7d)"
        end

      _ ->
        nil
    end
  end

  defp completeness_subtitle(_), do: nil

  defp pcts_from_history(history) do
    Enum.flat_map(history, fn
      %{payload: %{"overall_completeness_pct" => pct}} when is_number(pct) -> [pct]
      _ -> []
    end)
  end

  defp alert_count(:error), do: "—"

  defp alert_count(%{domains: domains}) when is_map(domains) do
    n =
      domains
      |> Map.values()
      |> Enum.flat_map(&(&1.checks || []))
      |> Enum.count(&(&1.status in [:amber, :red]))

    Integer.to_string(n)
  end

  defp alert_count(_), do: "—"

  defp alert_accent(:error), do: :zinc

  defp alert_accent(%{status: :red}), do: :red
  defp alert_accent(%{status: :amber}), do: :amber
  defp alert_accent(_), do: :green

  defp top_alert_label(:error), do: nil

  defp top_alert_label(%{worst_check: %{check: name}}) when is_atom(name) or is_binary(name) do
    "Worst: #{name}"
  end

  defp top_alert_label(_), do: nil

  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_dt(_), do: "—"

  # =========================================================================
  # Nav grid (Phase 0 carryover, expanded with Phase 1 routes)
  # =========================================================================

  defp sections do
    [
      %{
        title: "Observability",
        description: "Drift, queues, jobs, and Oban internals.",
        cards: [
          %{
            title: "Health",
            path: "/admin/health",
            description: "Six-domain drift verdicts, activity strip, 30-day completeness chart."
          },
          %{
            title: "Queues",
            path: "/admin/queues",
            description: "Per-queue Oban state, longest-running, recent failures."
          },
          %{
            title: "Jobs",
            path: "/admin/jobs",
            description: "Per-worker execution metrics with time-range selector."
          },
          %{
            title: "Scheduled",
            path: "/admin/scheduled",
            description: "All 24 cron entries with Trigger Now."
          },
          %{
            title: "Oban",
            path: "/admin/oban",
            description: "Embedded Oban Web — raw job queue browser."
          }
        ]
      },
      %{
        title: "Data",
        description: "Imports, festivals, lists.",
        cards: [
          %{
            title: "Imports",
            path: "/admin/imports",
            description: "Real-time TMDb bulk import progress."
          },
          %{
            title: "Year imports",
            path: "/admin/year-imports",
            description: "Year-by-year TMDb completion tracking."
          },
          %{
            title: "Award imports",
            path: "/admin/award-imports",
            description: "Festival/awards import orchestration."
          },
          %{
            title: "Festivals",
            path: "/admin/festivals",
            description: "Edit festival organizations: identity, imagery, links to audit."
          },
          %{
            title: "Festival events",
            path: "/admin/festival-events",
            description: "Legacy import-config modal (folds into Festivals editor in Phase 3)."
          },
          %{
            title: "Festival audit",
            path: "/admin/festival",
            description: "Browse organizations, ceremonies, switch/delete nominations."
          },
          %{
            title: "Lists",
            path: "/admin/lists-manager",
            description: "Curated canonical-list editor (IMDb lists)."
          }
        ]
      },
      %{
        title: "Data Quality",
        description: "Per-domain drift drilldowns + audits.",
        cards: [
          %{
            title: "Movies",
            path: "/admin/movies",
            description: "OMDb / IMDb-id / availability gaps."
          },
          %{
            title: "People",
            path: "/admin/people",
            description: "Profile, biography, PQS coverage."
          },
          %{
            title: "Ratings",
            path: "/admin/ratings",
            description: "OMDb backlog and stale ratings."
          },
          %{
            title: "Availability",
            path: "/admin/availability",
            description: "Watch-availability provider coverage."
          },
          %{
            title: "Collaborations",
            path: "/admin/collaborations",
            description: "Collaboration graph health."
          },
          %{
            title: "Companies",
            path: "/admin/companies",
            description: "Production companies — logo / slug / metadata."
          },
          %{
            title: "Audits",
            path: "/admin/audits",
            description: "Run any registered cinegraph.audit.* task."
          }
        ]
      },
      %{
        title: "Quality",
        description: "Scoring, calibration, predictions.",
        cards: [
          %{
            title: "Metrics",
            path: "/admin/metrics",
            description: "Metric definitions, weight profiles, coverage statistics."
          },
          %{
            title: "Predictions",
            path: "/admin/predictions",
            description: "1001-2020s movie prediction candidate list."
          },
          %{
            title: "Score calibration",
            path: "/admin/score-calibration",
            description: "Compare Cinegraph scores vs reference datasets."
          }
        ]
      }
    ]
  end
end
