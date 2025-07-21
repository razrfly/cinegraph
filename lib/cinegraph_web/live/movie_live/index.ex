defmodule CinegraphWeb.MovieLive.Index do
  use CinegraphWeb, :live_view

  alias Cinegraph.Movies

  @impl true
  def mount(_params, _session, socket) do
    movies = Movies.list_movies()
    {:ok, assign(socket, :movies, movies)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Movies Database")
  end
end