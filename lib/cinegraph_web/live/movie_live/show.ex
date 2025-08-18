defmodule CinegraphWeb.MovieLive.Show do
  use CinegraphWeb, :live_view
  import CinegraphWeb.CollaborationComponents, only: [format_ordinal: 1]

  alias Cinegraph.Movies
  alias Cinegraph.Cultural
  alias Cinegraph.ExternalSources
  alias Cinegraph.Collaborations
  alias Cinegraph.Metrics
  alias Cinegraph.Repo

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :active_tab, "overview")}
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
    
    # Calculate real Cinegraph scores
    score_data = calculate_movie_scores(movie)

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
    
    # Get related movies by collaboration
    related_movies = get_related_movies_by_collaboration(movie, cast, crew)
    
    # Get collaboration timelines for key partnerships
    collaboration_timelines = get_collaboration_timelines(movie, key_collaborations)

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
  
  defp calculate_movie_scores(movie) do
    # Get external metrics for this movie
    query = """
    SELECT 
      MAX(CASE WHEN source = 'imdb' AND metric_type = 'rating_average' THEN value END) as imdb_rating,
      MAX(CASE WHEN source = 'imdb' AND metric_type = 'rating_votes' THEN value END) as imdb_votes,
      MAX(CASE WHEN source = 'tmdb' AND metric_type = 'rating_average' THEN value END) as tmdb_rating,
      MAX(CASE WHEN source = 'tmdb' AND metric_type = 'rating_votes' THEN value END) as tmdb_votes,
      MAX(CASE WHEN source = 'metacritic' AND metric_type = 'metascore' THEN value END) as metacritic,
      MAX(CASE WHEN source = 'rotten_tomatoes' AND metric_type = 'tomatometer' THEN value END) as rt_tomatometer,
      MAX(CASE WHEN source = 'rotten_tomatoes' AND metric_type = 'audience_score' THEN value END) as rt_audience,
      MAX(CASE WHEN source = 'tmdb' AND metric_type = 'popularity_score' THEN value END) as popularity
    FROM external_metrics
    WHERE movie_id = $1
    """
    
    metrics = case Repo.query(query, [movie.id]) do
      {:ok, %{rows: [row]}} -> 
        Enum.zip([:imdb_rating, :imdb_votes, :tmdb_rating, :tmdb_votes, :metacritic, :rt_tomatometer, :rt_audience, :popularity], row)
        |> Map.new()
      _ -> %{}
    end
    
    # Get festival data
    festival_query = """
    SELECT 
      COUNT(CASE WHEN won = true THEN 1 END) as wins,
      COUNT(*) as nominations
    FROM festival_nominations
    WHERE movie_id = $1
    """
    
    festival_data = case Repo.query(festival_query, [movie.id]) do
      {:ok, %{rows: [[wins, nominations]]}} -> %{wins: wins || 0, nominations: nominations || 0}
      _ -> %{wins: 0, nominations: 0}
    end
    
    # Get average person quality
    person_query = """
    SELECT AVG(pm.score) as avg_quality
    FROM movie_credits mc
    JOIN person_metrics pm ON pm.person_id = mc.person_id
    WHERE mc.movie_id = $1 AND pm.metric_type = 'quality_score'
    """
    
    person_quality = case Repo.query(person_query, [movie.id]) do
      {:ok, %{rows: [[avg]]}} when not is_nil(avg) -> 
        case avg do
          %Decimal{} -> Decimal.to_float(avg)
          num when is_number(num) -> num / 1.0  # Ensure it's a float
          _ -> 50.0
        end
      _ -> 50.0
    end
    
    # Get collaboration score (based on repeat collaborations)
    collab_query = """
    SELECT AVG(collaboration_count) as avg_collab
    FROM (
      SELECT c.collaboration_count
      FROM collaborations c
      JOIN movie_credits mc1 ON mc1.person_id = c.person_a_id
      JOIN movie_credits mc2 ON mc2.person_id = c.person_b_id
      WHERE mc1.movie_id = $1 AND mc2.movie_id = $1
      LIMIT 20
    ) sub
    """
    
    collab_score = case Repo.query(collab_query, [movie.id]) do
      {:ok, %{rows: [[avg]]}} when not is_nil(avg) -> 
        # Convert average collaboration count to a score (more collabs = higher score)
        avg_val = case avg do
          %Decimal{} -> Decimal.to_float(avg)
          num when is_number(num) -> num / 1.0
          _ -> 0.0
        end
        min(100.0, avg_val * 15.0)
      _ -> 50.0
    end
    
    # Calculate component scores (0-10 scale)
    popular_opinion = calculate_popular_opinion(metrics)
    critical_acclaim = calculate_critical_acclaim(metrics)
    industry_recognition = calculate_industry_recognition(festival_data)
    cultural_impact = calculate_cultural_impact(movie, metrics)
    people_quality_score = person_quality / 10.0  # Convert from 0-100 to 0-10
    collaboration_intelligence = collab_score / 10.0  # Convert from 0-100 to 0-10
    
    # Calculate overall score (weighted average)
    overall = (popular_opinion * 0.25 + 
               critical_acclaim * 0.20 + 
               industry_recognition * 0.15 + 
               cultural_impact * 0.15 + 
               people_quality_score * 0.15 + 
               collaboration_intelligence * 0.10)
    
    %{
      overall_score: Float.round(overall, 1),
      components: %{
        popular_opinion: Float.round(popular_opinion, 1),
        critical_acclaim: Float.round(critical_acclaim, 1),
        industry_recognition: Float.round(industry_recognition, 1),
        cultural_impact: Float.round(cultural_impact, 1),
        people_quality: Float.round(people_quality_score, 1),
        collaboration_intelligence: Float.round(collaboration_intelligence, 1)
      },
      raw_metrics: metrics
    }
  end
  
  defp calculate_popular_opinion(metrics) do
    imdb = Map.get(metrics, :imdb_rating, 0) || 0
    tmdb = Map.get(metrics, :tmdb_rating, 0) || 0
    rt_audience = Map.get(metrics, :rt_audience, 0) || 0
    
    scores = [imdb, tmdb, rt_audience / 10.0] |> Enum.filter(&(&1 > 0))
    
    if length(scores) > 0 do
      Enum.sum(scores) / length(scores)
    else
      5.0
    end
  end
  
  defp calculate_critical_acclaim(metrics) do
    metacritic = Map.get(metrics, :metacritic, 0) || 0
    rt_tomatometer = Map.get(metrics, :rt_tomatometer, 0) || 0
    
    scores = [metacritic / 10.0, rt_tomatometer / 10.0] |> Enum.filter(&(&1 > 0))
    
    if length(scores) > 0 do
      Enum.sum(scores) / length(scores)
    else
      5.0
    end
  end
  
  defp calculate_industry_recognition(festival_data) do
    wins = Map.get(festival_data, :wins, 0)
    nominations = Map.get(festival_data, :nominations, 0)
    
    # Score based on wins and nominations (capped at 10)
    min(10.0, wins * 2.0 + nominations * 0.5)
  end
  
  defp calculate_cultural_impact(movie, metrics) do
    # Check canonical sources
    canonical_count = if movie.canonical_sources && map_size(movie.canonical_sources) > 0 do
      map_size(movie.canonical_sources)
    else
      0
    end
    
    # Check popularity
    popularity = Map.get(metrics, :popularity, 0) || 0
    popularity_score = if popularity > 0 do
      :math.log(popularity + 1) / :math.log(1000)  # Normalize on log scale
    else
      0
    end
    
    # Combine canonical presence and popularity
    min(10.0, canonical_count * 2.0 + popularity_score * 5.0)
  end
  
  defp get_related_movies_by_collaboration(movie, cast, crew) do
    # Get top cast and crew IDs
    person_ids = 
      (Enum.take(cast, 5) ++ Enum.filter(crew, &(&1.job in ["Director", "Writer", "Producer"]))
       |> Enum.take(3))
      |> Enum.map(& &1.person_id)
      |> Enum.uniq()
    
    if length(person_ids) == 0 do
      []
    else
      # Find movies with shared cast/crew
      query = """
    WITH shared_people AS (
      SELECT 
        mc.movie_id,
        COUNT(DISTINCT mc.person_id) as shared_count,
        array_agg(DISTINCT p.name) as shared_names
      FROM movie_credits mc
      JOIN people p ON p.id = mc.person_id
      WHERE mc.person_id = ANY($1::int[])
        AND mc.movie_id != $2
      GROUP BY mc.movie_id
      HAVING COUNT(DISTINCT mc.person_id) >= 2
    )
    SELECT 
      m.id, m.title, m.release_date, m.poster_path, m.slug,
      sp.shared_count, sp.shared_names
    FROM movies m
    JOIN shared_people sp ON sp.movie_id = m.id
    WHERE m.import_status = 'full'
    ORDER BY sp.shared_count DESC, m.release_date DESC
    LIMIT 8
    """
    
      case Repo.query(query, [person_ids, movie.id]) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [id, title, release_date, poster_path, slug, shared_count, shared_names] ->
            %{
              id: id,
              title: title,
              release_date: release_date,
              poster_path: poster_path,
              slug: slug,
              shared_count: shared_count,
              shared_names: shared_names,
              connection_reason: format_connection_reason(shared_count, shared_names)
            }
          end)
        _ -> []
      end
    end
  end
  
  defp format_connection_reason(count, names) do
    case count do
      1 -> "Shares #{Enum.at(names, 0)}"
      2 -> "Shares #{Enum.join(names, " & ")}"
      _ -> "Shares #{count} cast/crew members"
    end
  end
  
  defp get_collaboration_timelines(_movie, key_collaborations) do
    # For each key collaboration, get their film history together
    timelines = []
    
    # Get director-actor timelines
    for collab <- key_collaborations.director_actor_reunions do
      movies = Collaborations.find_actor_director_movies(
        collab.person_a.id, 
        collab.person_b.id
      )
      
      timeline_movies = Enum.map(movies, fn m ->
        # Get score for each movie
        score_query = """
        SELECT AVG(value) 
        FROM external_metrics 
        WHERE movie_id = $1 
          AND source IN ('imdb', 'tmdb') 
          AND metric_type = 'rating_average'
        """
        
        avg_score = case Repo.query(score_query, [m.id]) do
          {:ok, %{rows: [[score]]}} when not is_nil(score) -> 
            score_val = case score do
              %Decimal{} -> Decimal.to_float(score)
              num when is_number(num) -> num / 1.0
              _ -> 0.0
            end
            Float.round(score_val, 1)
          _ -> nil
        end
        
        Map.put(m, :score, avg_score)
      end)
      
      %{
        type: :director_actor,
        person_a: collab.person_a,
        person_b: collab.person_b,
        movies: timeline_movies,
        collaboration_strength: calculate_collaboration_strength(timeline_movies)
      }
    end
    
    timelines
  end
  
  defp calculate_collaboration_strength(movies) do
    # Based on number of movies and their average score
    count = length(movies)
    avg_score = if count > 0 do
      scores = movies |> Enum.map(&Map.get(&1, :score)) |> Enum.filter(&(not is_nil(&1)))
      if length(scores) > 0 do
        Enum.sum(scores) / length(scores)
      else
        5.0
      end
    else
      5.0
    end
    
    # Strength is combination of quantity and quality
    min(10.0, count * 2.0 + avg_score / 2.0)
  end
end
