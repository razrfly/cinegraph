defmodule CinegraphWeb.NowPlayingLive do
  @moduledoc """
  Public landing page for movies currently playing in theaters.

  Data comes from `Movies.Cache.now_playing_movies/1`, which is stamped every
  6 hours by `NowPlayingSweeper`. Films absent from all TMDB regions for more
  than 3 days drop off automatically — no manual curation required.

  The list is split into two sections at render time:
    - New Releases  — released within the last 18 months, sorted newest first
    - Classic Screenings — older films currently playing (re-releases, anniversary
      runs, repertoire cinema), sorted by CineGraph score, shown on demand
  """
  use CinegraphWeb, :live_view

  alias Cinegraph.Movies.{Cache, Movie}
  alias CinegraphWeb.Helpers.WombieLinks

  # Films released more than this many days ago are "classic screenings"
  @new_release_days 548

  @impl true
  def mount(_params, _session, socket) do
    movies = Cache.now_playing_movies()
    cutoff = Date.add(Date.utc_today(), -@new_release_days)

    {new_movies, classic_movies} =
      Enum.split_with(movies, fn m ->
        m.release_date && Date.compare(m.release_date, cutoff) in [:gt, :eq]
      end)

    new_releases = Enum.sort_by(new_movies, & &1.release_date, {:desc, Date})
    classic_screenings = Enum.sort_by(classic_movies, &score_for_sort/1, :desc)

    last_updated_at =
      movies
      |> Enum.map(& &1.now_playing_last_seen)
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> nil
        stamps -> Enum.max(stamps, DateTime)
      end

    {:ok,
     socket
     |> assign(:page_title, "Now Playing")
     |> assign(:new_release_cards, Enum.map(new_releases, &build_film_card/1))
     |> assign(:classic_cards, Enum.map(classic_screenings, &build_film_card/1))
     |> assign(:last_updated_at, last_updated_at)
     |> assign(:show_classics, false)}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_classics", _params, socket) do
    {:noreply, update(socket, :show_classics, &(!&1))}
  end

  def format_freshness(nil), do: nil

  def format_freshness(dt) do
    hours = div(DateTime.diff(DateTime.utc_now(), dt, :second), 3600)

    cond do
      hours < 1 -> "just now"
      hours == 1 -> "1 hour ago"
      hours < 24 -> "#{hours} hours ago"
      true -> "#{div(hours, 24)} days ago"
    end
  end

  defp score_for_sort(%{score_cache: %{overall_score: s}}) when is_number(s), do: s
  defp score_for_sort(_), do: -1.0

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
      score_tooltip: "Cinegraph score",
      wombie_url: WombieLinks.showtimes_url(movie, "now_playing")
    }
  end
end
