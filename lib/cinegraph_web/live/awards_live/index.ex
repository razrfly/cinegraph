defmodule CinegraphWeb.AwardsLive.Index do
  @moduledoc """
  LiveView for browsing all festival/awards organizations.
  Provides a clean entry point at /awards showing available festivals.
  """
  use CinegraphWeb, :live_view

  alias Cinegraph.Festivals

  @impl true
  def mount(_params, _session, socket) do
    organizations = organizations_with_stats()

    {:ok,
     socket
     |> assign(:page_title, "Awards & Festivals")
     |> assign(:active_nav, "Awards")
     |> assign(:all_organizations, organizations)
     |> assign(:organizations, organizations)
     |> assign(:category, "all")
     |> assign(:search, "")
     |> assign(:sort, "name")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    category = params["category"] || "all"
    search = params["search"] || ""
    sort = params["sort"] || "name"

    organizations =
      socket.assigns.all_organizations
      |> filter_organizations(category, search)
      |> sort_organizations(sort)

    {:noreply,
     socket
     |> assign(:organizations, organizations)
     |> assign(:category, category)
     |> assign(:search, search)
     |> assign(:sort, sort)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    query =
      params
      |> Map.take(["category", "search", "sort"])
      |> Enum.reject(fn {_key, value} -> value in [nil, "", "all", "name"] end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/awards?#{query}")}
  end

  defp filter_organizations(orgs, category, search) do
    query = String.downcase(search || "")

    Enum.filter(orgs, fn org ->
      category_match? =
        case category do
          "all" -> true
          "a-list" -> (org.prestige_tier || 99) <= 1
          "major" -> (org.prestige_tier || 99) <= 2
          "with-winners" -> org.winner_count > 0
          _ -> true
        end

      search_match? =
        query == "" ||
          String.contains?(String.downcase(org.name || ""), query) ||
          String.contains?(String.downcase(org.abbreviation || ""), query) ||
          String.contains?(String.downcase(org.country || ""), query)

      category_match? && search_match?
    end)
  end

  defp sort_organizations(orgs, "films"), do: Enum.sort_by(orgs, & &1.movie_count, :desc)
  defp sort_organizations(orgs, "winners"), do: Enum.sort_by(orgs, & &1.winner_count, :desc)
  defp sort_organizations(orgs, _), do: Enum.sort_by(orgs, &String.downcase(&1.name || ""))

  defp organizations_with_stats do
    stats_by_id = Festivals.organization_stats_by_id()

    Enum.map(Festivals.list_organizations(), fn org ->
      stats = Map.get(stats_by_id, org.id, %{movie_count: 0, winner_count: 0})

      org
      |> Map.put(:movie_count, stats.movie_count)
      |> Map.put(:winner_count, stats.winner_count)
    end)
  end
end
