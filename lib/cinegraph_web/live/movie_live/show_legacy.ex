defmodule CinegraphWeb.MovieLive.ShowLegacy do
  use CinegraphWeb, :live_view
  import CinegraphWeb.CollaborationComponents, only: [format_ordinal: 1]

  alias Cinegraph.Movies
  alias Cinegraph.Cultural
  alias Cinegraph.ExternalSources
  alias Cinegraph.Collaborations
  alias Cinegraph.Metrics

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id_or_slug" => id_or_slug}, _url, socket) do
    movie = load_movie_by_id_or_slug(id_or_slug)

    # Redirect to canonical URL if accessed by ID
    socket =
      if is_numeric_id?(id_or_slug) and movie.slug do
        socket
        |> push_navigate(to: ~p"/movies/#{movie.slug}/legacy")
      else
        socket
        |> assign(:movie, load_movie_with_all_data(movie.id))
        |> assign(:page_title, "#{movie.title} (Legacy)")
      end

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

    # Get key collaborations for this movie
    key_collaborations = get_key_collaborations(cast, crew)

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
  end

  defp get_key_collaborations(cast, crew) do
    # Get directors
    directors = Enum.filter(crew, &(&1.job == "Director"))

    # Get top actors
    top_actors = Enum.take(cast, 10)

    # Director-Actor reunions
    director_actor_reunions =
      for director <- directors,
          actor <- top_actors do
        case Collaborations.find_actor_director_movies(actor.person_id, director.person_id) do
          movies when length(movies) > 1 ->
            %{
              type: :director_actor,
              person_a: actor.person,
              person_b: director.person,
              collaboration_count: length(movies),
              is_reunion: true
            }

          _ ->
            nil
        end
      end
      |> Enum.reject(&is_nil/1)

    # Actor-Actor partnerships
    actor_partnerships =
      for {actor1, idx} <- Enum.with_index(top_actors),
          actor2 <- Enum.slice(top_actors, (idx + 1)..-1//1) do
        query = """
        SELECT c.collaboration_count
        FROM collaborations c
        WHERE (c.person_a_id = $1 AND c.person_b_id = $2)
           OR (c.person_a_id = $2 AND c.person_b_id = $1)
        """

        case Cinegraph.Repo.query(query, [actor1.person_id, actor2.person_id]) do
          {:ok, %{rows: [[count]]}} when count > 1 ->
            %{
              type: :actor_actor,
              person_a: actor1.person,
              person_b: actor2.person,
              collaboration_count: count,
              is_reunion: true
            }

          _ ->
            nil
        end
      end
      |> Enum.reject(&is_nil/1)

    # Combine and sort by collaboration count
    all_collaborations =
      (director_actor_reunions ++ actor_partnerships)
      |> Enum.sort_by(& &1.collaboration_count, :desc)
      |> Enum.take(6)

    %{
      director_actor_reunions: Enum.filter(all_collaborations, &(&1.type == :director_actor)),
      actor_partnerships: Enum.filter(all_collaborations, &(&1.type == :actor_actor)),
      total_reunions: length(all_collaborations)
    }
  end
end
