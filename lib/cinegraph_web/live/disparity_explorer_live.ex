defmodule CinegraphWeb.DisparityExplorerLive do
  use CinegraphWeb, :live_view

  alias Cinegraph.Movies

  @tabs [
    %{id: "critics_darling", label: "Critics' Darlings", icon: "🎭"},
    %{id: "peoples_champion", label: "People's Champions", icon: "🔥"},
    %{id: "perfect_harmony", label: "Perfect Harmony", icon: "✨"},
    %{id: "polarizer", label: "The Polarizers", icon: "⚡"}
  ]

  @per_page 24

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:tabs, @tabs)
     |> assign(:active_tab, "critics_darling")
     |> assign(:page, 1)
     |> assign(:movies, [])
     |> assign(:per_page, @per_page)
     |> load_movies("critics_darling")}
  end

  @impl true
  def handle_params(%{"tab" => tab}, _url, socket)
      when tab in ~w(critics_darling peoples_champion perfect_harmony polarizer) do
    {:noreply,
     socket
     |> assign(:active_tab, tab)
     |> assign(:page, 1)
     |> load_movies(tab)}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply,
     socket
     |> assign(:active_tab, tab)
     |> assign(:page, 1)
     |> assign(:movies, [])
     |> push_patch(to: ~p"/explore/disparity?tab=#{tab}")}
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    next_page = socket.assigns.page + 1

    {:noreply,
     socket
     |> assign(:page, next_page)
     |> load_more_movies(socket.assigns.active_tab, next_page)}
  end

  defp load_movies(socket, category) do
    movies = Movies.list_movies_by_disparity_category(category, limit: @per_page)
    assign(socket, :movies, movies)
  end

  defp load_more_movies(socket, category, page) do
    offset = (page - 1) * @per_page

    new_movies =
      Movies.list_movies_by_disparity_category(category, limit: @per_page, offset: offset)

    assign(socket, :movies, socket.assigns.movies ++ new_movies)
  end

  defp disparity_label("critics_darling"), do: "Critics' Darling"
  defp disparity_label("peoples_champion"), do: "People's Champion"
  defp disparity_label("perfect_harmony"), do: "Perfect Harmony"
  defp disparity_label("polarizer"), do: "The Polarizer"
  defp disparity_label(_), do: "—"

  defp disparity_badge_class("critics_darling"), do: "bg-purple-600/80 text-white"
  defp disparity_badge_class("peoples_champion"), do: "bg-orange-500/80 text-white"
  defp disparity_badge_class("perfect_harmony"), do: "bg-teal-500/80 text-white"
  defp disparity_badge_class("polarizer"), do: "bg-yellow-500/80 text-gray-900"
  defp disparity_badge_class(_), do: "bg-gray-500/80 text-white"
end
