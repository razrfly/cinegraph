defmodule CinegraphWeb.ListLive.Index do
  @moduledoc """
  LiveView for browsing all curated lists.
  Provides a clean entry point at /lists showing available movie collections.
  """
  use CinegraphWeb, :live_view

  alias Cinegraph.Lists.ListSlugs
  alias Cinegraph.Movies

  @categories ~w(all critics curated registry)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Lists")
     |> assign(:active_nav, "Lists")
     |> assign(:lists, [])
     |> assign(:category, "all")
     |> assign(:search, "")
     |> assign(:sort, "display")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    category = normalize_category(params["category"])
    search = params["search"] || ""
    sort = params["sort"] || "display"

    lists =
      ListSlugs.all()
      |> Enum.map(fn list ->
        list
        |> Map.put(:movie_count, Movies.count_movies_in_list(list.key))
        |> Map.put(:category, list[:category] || list["category"] || "curated")
      end)
      |> filter_lists(category, search)
      |> sort_lists(sort)

    {:noreply,
     socket
     |> assign(:lists, lists)
     |> assign(:category, category)
     |> assign(:search, search)
     |> assign(:sort, sort)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    query =
      params
      |> Map.take(["category", "search", "sort"])
      |> Enum.reject(fn {_key, value} -> value in [nil, "", "all", "display"] end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/lists?#{query}")}
  end

  defp filter_lists(lists, "all", ""), do: lists

  defp filter_lists(lists, category, search) do
    query = String.downcase(search || "")

    Enum.filter(lists, fn list ->
      category_match? = category == "all" || to_string(list.category) == category

      search_match? =
        query == "" ||
          String.contains?(String.downcase(list.name || ""), query) ||
          String.contains?(String.downcase(list.description || ""), query)

      category_match? && search_match?
    end)
  end

  defp sort_lists(lists, "name"), do: Enum.sort_by(lists, &String.downcase(&1.name || ""))
  defp sort_lists(lists, "films"), do: Enum.sort_by(lists, & &1.movie_count, :desc)
  defp sort_lists(lists, _), do: lists

  defp normalize_category(category) when category in @categories, do: category
  defp normalize_category(_category), do: "all"
end
