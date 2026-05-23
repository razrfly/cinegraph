defmodule CinegraphWeb.NowPlayingLive do
  @moduledoc """
  Public landing page for movies currently playing in theaters.

  Data comes from `Movies.Cache.now_playing_movies/1`, which is stamped every
  6 hours by `NowPlayingSweeper`. Films absent from all TMDB regions for more
  than 3 days drop off automatically — no manual curation required.
  """
  use CinegraphWeb, :live_view

  alias Cinegraph.Movies.{Cache, Movie}

  @impl true
  def mount(_params, _session, socket) do
    movies = Cache.now_playing_movies()
    film_cards = Enum.map(movies, &build_film_card/1)

    {:ok,
     socket
     |> assign(:page_title, "Now Playing")
     |> assign(:film_cards, film_cards)
     |> assign(:movie_count, length(movies))}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp build_film_card(movie) do
    score =
      case movie.score_cache do
        %{overall_score: s} when is_number(s) -> Float.round(s * 1.0, 1)
        _ -> nil
      end

    %{
      id: movie.id,
      title: movie.title,
      year: movie.release_date && movie.release_date.year,
      href: "/movies/#{movie.slug || movie.id}",
      poster_url: Movie.poster_url(movie, "w342"),
      score: score,
      lens_key: score && :overall,
      score_tooltip: "Cinegraph score"
    }
  end
end
