defmodule CinegraphWeb.Admin.ImportsLive do
  @moduledoc """
  Tabbed wrapper for the three import dashboards (#880 Phase 4).

  Replaces the previous trio of separate routes. The tab strip is rendered
  here; each tab embeds the corresponding existing LiveView via
  `live_render/3` so we don't have to merge ~2.4k lines of templates.

  - `?tab=tmdb`   → TMDb bulk import dashboard (default)
  - `?tab=years`  → Year-by-year backfill management
  - `?tab=awards` → Awards / festivals import dashboard

  The legacy routes `/admin/year-imports` and `/admin/award-imports` redirect
  here via `AdminRedirectLive` (router-level).
  """
  use CinegraphWeb, :live_view

  alias CinegraphWeb.{ImportDashboardLive, YearImportsLive, AwardImportsLive}

  @tabs [
    %{id: "tmdb", label: "TMDb bulk", module: ImportDashboardLive},
    %{id: "years", label: "Year backfill", module: YearImportsLive},
    %{id: "awards", label: "Awards", module: AwardImportsLive}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :tabs, @tabs)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = normalize_tab(params["tab"])

    {:noreply,
     socket
     |> assign(:active_tab, tab)
     |> assign(:page_title, page_title(tab))}
  end

  defp normalize_tab(tab) when tab in ["tmdb", "years", "awards"], do: tab
  defp normalize_tab(_), do: "tmdb"

  defp page_title("tmdb"), do: "Imports · TMDb bulk"
  defp page_title("years"), do: "Imports · Year backfill"
  defp page_title("awards"), do: "Imports · Awards"

  defp active_module("tmdb"), do: ImportDashboardLive
  defp active_module("years"), do: YearImportsLive
  defp active_module("awards"), do: AwardImportsLive

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <header>
        <h1 class="text-2xl font-semibold tracking-tight text-zinc-900">Imports</h1>
        <p class="mt-1 text-sm text-zinc-600">
          Bulk-load movies, backfill specific years, and manage festival/awards data.
        </p>
      </header>

      <nav class="flex gap-1 border-b border-zinc-200" aria-label="Imports tabs">
        <.link
          :for={tab <- @tabs}
          patch={~p"/admin/imports?tab=#{tab.id}"}
          class={tab_class(tab.id == @active_tab)}
          aria-current={if tab.id == @active_tab, do: "page", else: "false"}
        >
          {tab.label}
        </.link>
      </nav>

      <div id={"imports-tab-#{@active_tab}"}>
        {live_render(@socket, active_module(@active_tab),
          id: "imports-tab-content-#{@active_tab}",
          sticky: false
        )}
      </div>
    </div>
    """
  end

  defp tab_class(true) do
    "px-4 py-2.5 text-sm font-medium border-b-2 border-blue-600 text-blue-700 -mb-px"
  end

  defp tab_class(false) do
    "px-4 py-2.5 text-sm font-medium border-b-2 border-transparent text-zinc-600 hover:text-zinc-900 hover:border-zinc-300 -mb-px"
  end
end
