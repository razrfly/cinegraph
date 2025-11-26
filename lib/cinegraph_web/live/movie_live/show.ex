defmodule CinegraphWeb.MovieLive.Show do
  use CinegraphWeb, :live_view
  import CinegraphWeb.CollaborationComponents, only: [format_ordinal: 1]

  alias Cinegraph.Movies
  alias Cinegraph.Cultural
  alias Cinegraph.ExternalSources
  alias Cinegraph.Metrics
  alias Cinegraph.Metrics.ApiLookupMetric
  alias Cinegraph.Movies.MovieScoring
  alias Cinegraph.Movies.MovieCollaborations
  alias Cinegraph.Repo

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active_tab, "overview")
     |> assign(:show_score_modal, false)}
  end

  # Handle TMDb ID route - for external project linking
  @impl true
  def handle_params(%{"tmdb_id" => tmdb_id}, _url, socket) do
    case parse_tmdb_id(tmdb_id) do
      {:ok, parsed_id} ->
        case fetch_or_create_movie_by_tmdb_id(parsed_id) do
          {:ok, movie} ->
            {:noreply, redirect_to_canonical_url(socket, movie)}

          {:error, :not_found} ->
            {:noreply,
             socket
             |> put_flash(:error, "Movie not found in TMDb database")
             |> push_navigate(to: ~p"/movies")}

          {:error, reason} ->
            Logger.error("Failed to fetch movie by TMDb ID #{parsed_id}: #{inspect(reason)}")

            {:noreply,
             socket
             |> put_flash(:error, "Error loading movie: #{format_error(reason)}")
             |> push_navigate(to: ~p"/movies")}
        end

      :error ->
        {:noreply,
         socket
         |> put_flash(:error, "Invalid TMDb ID. Expected a numeric ID.")
         |> push_navigate(to: ~p"/movies")}
    end
  end

  # Handle IMDb ID route - for cross-platform compatibility
  @impl true
  def handle_params(%{"imdb_id" => imdb_id}, _url, socket) do
    unless valid_imdb_id?(imdb_id) do
      {:noreply,
       socket
       |> put_flash(:error, "Invalid IMDb ID format. Expected: tt0000000")
       |> push_navigate(to: ~p"/movies")}
    else
      case fetch_or_create_movie_by_imdb_id(imdb_id) do
        {:ok, movie} ->
          {:noreply, redirect_to_canonical_url(socket, movie)}

        {:error, :not_found} ->
          {:noreply,
           socket
           |> put_flash(:error, "Movie not found with IMDb ID: #{imdb_id}")
           |> push_navigate(to: ~p"/movies")}

        {:error, reason} ->
          Logger.error("Failed to fetch movie by IMDb ID #{imdb_id}: #{inspect(reason)}")

          {:noreply,
           socket
           |> put_flash(:error, "Error loading movie: #{format_error(reason)}")
           |> push_navigate(to: ~p"/movies")}
      end
    end
  end

  @impl true
  def handle_params(%{"id_or_slug" => id_or_slug}, _url, socket) do
    movie = load_movie_by_id_or_slug(id_or_slug)

    # Redirect to canonical URL if accessed by ID
    socket =
      if is_numeric_id?(id_or_slug) and movie.slug do
        socket
        |> push_navigate(to: ~p"/movies/#{movie.slug}")
      else
        socket
        |> assign(:movie, load_movie_with_all_data(movie.id))
        |> assign(:page_title, movie.title)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_event("show_score_modal", _params, socket) do
    {:noreply, assign(socket, :show_score_modal, true)}
  end

  @impl true
  def handle_event("hide_score_modal", _params, socket) do
    {:noreply, assign(socket, :show_score_modal, false)}
  end

  @impl true
  def handle_event("stop_propagation", _params, socket) do
    {:noreply, socket}
  end

  defp load_movie_by_id_or_slug(id_or_slug) do
    if is_numeric_id?(id_or_slug) do
      Movies.get_movie!(id_or_slug)
    else
      Movies.get_movie_by_slug!(id_or_slug)
    end
  end

  defp is_numeric_id?(str) do
    case Integer.parse(str) do
      {_num, ""} -> true
      _ -> false
    end
  end

  defp load_movie_with_all_data(id) do
    # Load movie with all related data
    movie = Movies.get_movie!(id)

    # Load aggregated metrics for backward compatibility
    metrics = Metrics.get_movie_aggregates(id)

    # Calculate real Cinegraph scores using the context module
    score_data = MovieScoring.calculate_movie_scores(movie)

    # Load credits (cast and crew)
    credits = Movies.get_movie_credits(id)

    cast =
      Enum.filter(credits, &(&1.credit_type == "cast")) |> Enum.sort_by(&(&1.cast_order || 999))

    crew = Enum.filter(credits, &(&1.credit_type == "crew"))
    directors = Enum.filter(crew, &(&1.job == "Director"))

    # Load cultural data
    cultural_lists = Cultural.get_list_movies_for_movie(id)
    oscar_nominations = Cultural.get_movie_oscar_nominations(id)

    # Load external sources data
    external_ratings = ExternalSources.get_movie_ratings(id)

    # Load ALL other connected data
    keywords = Movies.get_movie_keywords(id)
    videos = Movies.get_movie_videos(id)
    release_dates = Movies.get_movie_release_dates(id)
    production_companies = Movies.get_movie_production_companies(id)

    # Load all external sources
    all_external_sources = ExternalSources.list_sources()

    # Check what data we're missing
    missing_data = %{
      has_keywords: length(keywords) > 0,
      has_videos: length(videos) > 0,
      has_release_dates: length(release_dates) > 0,
      has_credits: length(credits) > 0,
      has_production_companies: length(production_companies) > 0,
      has_external_ratings: length(external_ratings) > 0,
      keywords_count: length(keywords),
      videos_count: length(videos),
      credits_count: length(credits),
      release_dates_count: length(release_dates),
      production_companies_count: length(production_companies),
      external_ratings_count: length(external_ratings)
    }

    # Get key collaborations for this movie using context module
    key_collaborations = MovieCollaborations.get_key_collaborations(cast, crew)

    # Get related movies by collaboration using context module
    related_movies = MovieCollaborations.get_related_movies_by_collaboration(movie, cast, crew)

    # Get collaboration timelines for key partnerships using context module
    collaboration_timelines =
      MovieCollaborations.get_collaboration_timelines(movie, key_collaborations)

    movie
    # Add metrics data (budget, revenue, etc.)
    |> Map.merge(metrics)
    |> Map.put(:cast, cast)
    |> Map.put(:crew, crew)
    |> Map.put(:directors, directors)
    |> Map.put(:cultural_lists, cultural_lists)
    |> Map.put(:oscar_nominations, oscar_nominations)
    |> Map.put(:external_ratings, external_ratings)
    |> Map.put(:keywords, keywords)
    |> Map.put(:videos, videos)
    |> Map.put(:release_dates, release_dates)
    |> Map.put(:production_companies, production_companies)
    |> Map.put(:all_external_sources, all_external_sources)
    |> Map.put(:missing_data, missing_data)
    |> Map.put(:key_collaborations, key_collaborations)
    |> Map.put(:score_data, score_data)
    |> Map.put(:related_movies, related_movies)
    |> Map.put(:collaboration_timelines, collaboration_timelines)
  end

  # Helper functions for TMDb ID lookup route

  defp parse_tmdb_id(tmdb_id) when is_binary(tmdb_id) do
    case Integer.parse(tmdb_id) do
      {parsed_id, ""} when parsed_id > 0 -> {:ok, parsed_id}
      _ -> :error
    end
  end

  defp parse_tmdb_id(_), do: :error

  defp fetch_or_create_movie_by_tmdb_id(tmdb_id) do
    case Movies.get_movie_by_tmdb_id(tmdb_id) do
      nil ->
        # Movie doesn't exist, fetch from TMDb
        Logger.info("Auto-fetching movie from TMDb: #{tmdb_id}")
        fetch_and_create_from_tmdb(tmdb_id)

      movie ->
        # Movie already exists
        log_auto_fetch_attempt(tmdb_id, :found_existing, movie.id)
        {:ok, movie}
    end
  end

  defp fetch_and_create_from_tmdb(tmdb_id) do
    # Use existing comprehensive fetch logic
    case Movies.fetch_and_store_movie_comprehensive(tmdb_id) do
      {:ok, movie} ->
        # Log successful auto-fetch
        log_auto_fetch_attempt(tmdb_id, :created, movie.id)
        Logger.info("Successfully auto-fetched movie: #{movie.title} (TMDb ID: #{tmdb_id})")
        {:ok, movie}

      {:error, reason} ->
        # Log failed auto-fetch
        log_auto_fetch_attempt(tmdb_id, :failed, nil, reason)
        Logger.warning("Failed to auto-fetch movie with TMDb ID #{tmdb_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp redirect_to_canonical_url(socket, movie) do
    socket
    |> put_flash(:info, "Viewing: #{movie.title}")
    |> push_navigate(to: ~p"/movies/#{movie.slug}")
  end

  # IMDb-specific helper functions

  defp valid_imdb_id?(imdb_id) when is_binary(imdb_id) do
    # IMDb IDs: tt followed by 7-8 digits
    Regex.match?(~r/^tt\d{7,8}$/, imdb_id)
  end

  defp valid_imdb_id?(_), do: false

  defp fetch_or_create_movie_by_imdb_id(imdb_id) do
    case Movies.get_movie_by_imdb_id(imdb_id) do
      nil ->
        # Movie doesn't exist, use TMDb Find API then fetch
        Logger.info("Auto-fetching movie from TMDb using IMDb ID: #{imdb_id}")
        fetch_via_tmdb_find(imdb_id)

      movie ->
        # Movie already exists
        log_imdb_auto_fetch_attempt(imdb_id, :found_existing, movie.id)
        {:ok, movie}
    end
  end

  defp fetch_via_tmdb_find(imdb_id) do
    alias Cinegraph.Services.TMDb

    # Use TMDb Find API to get TMDb ID from IMDb ID
    case TMDb.find_by_imdb_id(imdb_id) do
      {:ok, %{"movie_results" => [%{"id" => tmdb_id} | _]}} ->
        Logger.info("Found TMDb ID #{tmdb_id} for IMDb ID #{imdb_id}")
        fetch_and_create_from_tmdb_via_imdb(imdb_id, tmdb_id)

      {:ok, %{"movie_results" => []}} ->
        log_imdb_auto_fetch_attempt(imdb_id, :not_found_in_tmdb, nil)
        Logger.warning("IMDb ID #{imdb_id} not found in TMDb")
        {:error, :not_found}

      {:error, reason} ->
        log_imdb_auto_fetch_attempt(imdb_id, :tmdb_api_failed, nil, reason)
        Logger.error("TMDb Find API failed for IMDb ID #{imdb_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_and_create_from_tmdb_via_imdb(imdb_id, tmdb_id) do
    case Movies.fetch_and_store_movie_comprehensive(tmdb_id) do
      {:ok, movie} ->
        # Log successful auto-fetch via IMDb
        log_imdb_auto_fetch_attempt(imdb_id, :created, movie.id, nil, tmdb_id)

        Logger.info(
          "Successfully auto-fetched movie: #{movie.title} (IMDb ID: #{imdb_id}, TMDb ID: #{tmdb_id})"
        )

        {:ok, movie}

      {:error, reason} ->
        # Log failed auto-fetch
        log_imdb_auto_fetch_attempt(imdb_id, :failed, nil, reason, tmdb_id)

        Logger.warning(
          "Failed to auto-fetch movie with IMDb ID #{imdb_id} (TMDb ID: #{tmdb_id}): #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp log_imdb_auto_fetch_attempt(imdb_id, status, movie_id, error \\ nil, tmdb_id \\ nil) do
    # Fire and forget logging
    Task.start(fn ->
      attrs = %{
        source: "tmdb",
        operation: "auto_fetch_via_imdb_link",
        target_identifier: imdb_id,
        success: status not in [:failed, :not_found_in_tmdb, :tmdb_api_failed],
        response_time_ms: 0,
        metadata: %{
          status: to_string(status),
          movie_id: movie_id,
          tmdb_id: tmdb_id,
          imdb_id: imdb_id,
          lookup_method: "tmdb_find_api",
          triggered_by: "external_link",
          route: "/movies/imdb/:imdb_id"
        }
      }

      attrs =
        if error do
          Map.merge(attrs, %{
            error_type: "auto_fetch_failed",
            error_message: format_error(error)
          })
        else
          attrs
        end

      %ApiLookupMetric{}
      |> ApiLookupMetric.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, _metric} ->
          Logger.debug("Logged IMDb auto-fetch attempt for #{imdb_id}")

        {:error, changeset} ->
          Logger.warning("Failed to log IMDb auto-fetch attempt: #{inspect(changeset.errors)}")
      end
    end)
  end

  defp log_auto_fetch_attempt(tmdb_id, status, movie_id, error \\ nil) do
    # Fire and forget logging
    Task.start(fn ->
      attrs = %{
        source: "tmdb",
        operation: "auto_fetch_via_external_link",
        target_identifier: to_string(tmdb_id),
        success: status != :failed,
        response_time_ms: 0,
        metadata: %{
          status: to_string(status),
          movie_id: movie_id,
          triggered_by: "external_link",
          route: "/movies/tmdb/:tmdb_id"
        }
      }

      attrs =
        if error do
          Map.merge(attrs, %{
            error_type: "auto_fetch_failed",
            error_message: format_error(error)
          })
        else
          attrs
        end

      %ApiLookupMetric{}
      |> ApiLookupMetric.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, _metric} ->
          Logger.debug("Logged auto-fetch attempt for TMDb ID #{tmdb_id}")

        {:error, changeset} ->
          Logger.warning("Failed to log auto-fetch attempt: #{inspect(changeset.errors)}")
      end
    end)
  end

  defp format_error(:not_found), do: "Movie not found in TMDb"
  defp format_error({:error, reason}), do: format_error(reason)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(_), do: "Unknown error"
end
