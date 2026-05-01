defmodule CinegraphWeb.AwardsLive.IndexLegacy do
  @moduledoc """
  LiveView for browsing all festival/awards organizations.
  Provides a clean entry point at /awards showing available festivals.
  """
  use CinegraphWeb, :live_view

  alias Cinegraph.Festivals

  @impl true
  def mount(_params, _session, socket) do
    stats_by_id = Festivals.organization_stats_by_id()

    organizations_with_stats =
      Enum.map(Festivals.list_organizations(), fn org ->
        stats = Map.get(stats_by_id, org.id, %{movie_count: 0, winner_count: 0})

        org
        |> Map.put(:movie_count, stats.movie_count)
        |> Map.put(:winner_count, stats.winner_count)
      end)

    {:ok,
     socket
     |> assign(:page_title, "Awards & Festivals")
     |> assign(:organizations, organizations_with_stats)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end
end
