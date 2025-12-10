defmodule CinegraphWeb.ListLive.Index do
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

    # Get movie counts for each list
    lists_with_counts =
      Enum.map(lists, fn list ->
        count = Movies.count_movies_in_list(list.key)
        Map.put(list, :movie_count, count)
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
