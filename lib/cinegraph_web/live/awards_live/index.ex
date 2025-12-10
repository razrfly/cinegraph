defmodule CinegraphWeb.AwardsLive.Index do
  @moduledoc """
  LiveView for browsing all festival/awards organizations.
  Provides a clean entry point at /awards showing available festivals.
  """
  use CinegraphWeb, :live_view

  alias Cinegraph.Festivals

  @impl true
  def mount(_params, _session, socket) do
    organizations = Festivals.list_organizations()

    # Enrich with counts
    organizations_with_stats =
      Enum.map(organizations, fn org ->
        movie_count = Festivals.count_movies_for_organization(org.id) || 0
        winner_count = Festivals.count_winners_for_organization(org.id) || 0

        org
        |> Map.put(:movie_count, movie_count)
        |> Map.put(:winner_count, winner_count)
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
