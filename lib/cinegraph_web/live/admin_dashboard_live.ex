defmodule CinegraphWeb.AdminDashboardLive do
  @moduledoc """
  Cinegraph admin home page (Phase 0 of issue #880).

  Renders a Catalyst-styled nav grid linking to each existing admin LiveView.
  Phase 1 will replace the cards with live KPI tiles fed from
  `Cinegraph.Health.{Verdict, Activity, Queues, Completeness}`.
  """
  use CinegraphWeb, :admin_live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Admin")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title="Cinegraph admin"
      subtitle="Phase 0 — chrome only. Live KPI tiles land in Phase 1 (#880)."
    >
      <:actions>
        <a
          href="/admin/health"
          class="text-sm font-medium text-blue-600 hover:text-blue-800"
        >
          Open homeostasis dashboard →
        </a>
      </:actions>
    </.page_header>

    <%= for section <- sections() do %>
      <.section_heading title={section.title} description={section.description} />
      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
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
              <span
                class="text-gray-400 group-hover:text-blue-600 shrink-0"
                aria-hidden="true"
              >
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

  defp sections do
    [
      %{
        title: "Observability",
        description: "Drift, queues, and Oban internals.",
        cards: [
          %{
            title: "Health",
            path: "/admin/health",
            description:
              "Six-domain drift verdicts, activity strip, queue health, 30-day completeness chart."
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
            title: "Festival events",
            path: "/admin/festival-events",
            description: "Festival event import-config CRUD."
          },
          %{
            title: "Festival audit",
            path: "/admin/festival",
            description: "Browse organizations, ceremonies, and switch/delete nominations."
          },
          %{
            title: "Lists",
            path: "/admin/lists-manager",
            description: "Curated canonical-list editor (IMDb lists)."
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
            description: "Compare Cinegraph scores vs. reference datasets and tune weights."
          }
        ]
      }
    ]
  end
end
