defmodule CinegraphWeb.ListLive.IndexLegacy do
  @moduledoc """
  LiveView for browsing all curated lists.
  Provides a clean entry point at /lists showing available movie collections.
  """
  use CinegraphWeb, :live_view

  alias Cinegraph.Lists.ListSlugs
  alias Cinegraph.Movies

  @impl true
  def mount(_params, _session, socket) do
    lists = ListSlugs.all()
    counts_by_key = Movies.count_movies_by_list_keys(Enum.map(lists, & &1.key))

    lists_with_counts =
      Enum.map(lists, fn list ->
        Map.put(list, :movie_count, Map.get(counts_by_key, list.key, 0))
      end)

    {:ok,
     socket
     |> assign(:page_title, "Curated Lists")
     |> assign(:lists, lists_with_counts)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end
end
