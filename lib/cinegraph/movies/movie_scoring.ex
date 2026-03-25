defmodule Cinegraph.Movies.MovieScoring do
  @moduledoc """
  Business logic for calculating movie scores and related metrics.
  Extracted from LiveView to improve separation of concerns.
  """

  alias Cinegraph.Repo
  alias Cinegraph.Scoring.{FestivalPrestige, Lenses}
  alias Cinegraph.Metrics.ScoringService

  # Helper to normalize DB numerics to floats
  def normalize_number(nil), do: nil
  def normalize_number(%Decimal{} = d), do: Decimal.to_float(d)
  def normalize_number(num) when is_integer(num), do: num / 1.0
  def normalize_number(num) when is_float(num), do: num
  def normalize_number(_), do: nil

  @doc """
  Calculate comprehensive scores for a movie using external metrics,
  festival data, person quality, and financial performance.

  Uses the standard 6-category scoring system:
  - The Mob (audience ratings from IMDb, TMDb)
  - The Critics (critics scores from Metacritic and RT Tomatometer)
  - Festival Recognition (festival wins and nominations)
  - The Time Machine (canonical sources and popularity)
  - The Auteurs (quality scores of cast and crew)
  - The Box Office (revenue and budget data)
  """
  def calculate_movie_scores(movie) do
    # Get external metrics for this movie
    query = """
    SELECT
      MAX(CASE WHEN source = 'imdb' AND metric_type = 'rating_average' THEN value END) as imdb_rating,
      MAX(CASE WHEN source = 'imdb' AND metric_type = 'rating_votes' THEN value END) as imdb_votes,
      MAX(CASE WHEN source = 'tmdb' AND metric_type = 'rating_average' THEN value END) as tmdb_rating,
      MAX(CASE WHEN source = 'tmdb' AND metric_type = 'rating_votes' THEN value END) as tmdb_votes,
      MAX(CASE WHEN source = 'metacritic' AND metric_type = 'metascore' THEN value END) as metacritic,
      MAX(CASE WHEN source = 'rotten_tomatoes' AND metric_type = 'tomatometer' THEN value END) as rt_tomatometer,
      MAX(CASE WHEN source = 'tmdb' AND metric_type = 'popularity_score' THEN value END) as popularity,
      MAX(CASE WHEN source = 'tmdb' AND metric_type = 'budget' THEN value END) as budget,
      MAX(CASE WHEN source = 'tmdb' AND metric_type = 'revenue_worldwide' THEN value END) as revenue
    FROM external_metrics
    WHERE movie_id = $1
    """

    metrics =
      case Repo.query(query, [movie.id]) do
        {:ok, %{rows: [row]}} ->
          Enum.zip(
            [
              :imdb_rating,
              :imdb_votes,
              :tmdb_rating,
              :tmdb_votes,
              :metacritic,
              :rt_tomatometer,
              :popularity,
              :budget,
              :revenue
            ],
            row
          )
          |> Map.new(fn {k, v} -> {k, normalize_number(v)} end)

        _ ->
          %{}
      end

    # Get festival data (win_score/nom_score enable DB-backed prestige tiers)
    festival_query = """
    SELECT fo.abbreviation, fc.name, fnom.won, fo.win_score, fo.nom_score
    FROM festival_nominations fnom
    JOIN festival_categories fc ON fnom.category_id = fc.id
    JOIN festival_ceremonies fcer ON fnom.ceremony_id = fcer.id
    JOIN festival_organizations fo ON fcer.organization_id = fo.id
    WHERE fnom.movie_id = $1
    """

    festival_data =
      case Repo.query(festival_query, [movie.id]) do
        {:ok, %{rows: rows}} -> rows
        _ -> []
      end

    # Get average person quality — role-weighted, deduplicated top-10
    person_query = """
    SELECT SUM(max_score * role_weight) / NULLIF(SUM(role_weight), 0) as avg_quality
    FROM (
      SELECT
        mc.person_id,
        MAX(pm.score) as max_score,
        MAX(CASE mc.department
          WHEN 'Directing'  THEN 3.0
          WHEN 'Writing'    THEN 1.5
          WHEN 'Production' THEN 1.0
          ELSE
            CASE WHEN mc.cast_order <= 3  THEN 2.0
                 WHEN mc.cast_order <= 10 THEN 1.5
                 ELSE 1.0
            END
        END) as role_weight
      FROM movie_credits mc
      JOIN person_metrics pm ON pm.person_id = mc.person_id
      WHERE mc.movie_id = $1 AND pm.metric_type = 'quality_score'
      GROUP BY mc.person_id
      ORDER BY MAX(pm.score) * MAX(CASE mc.department
          WHEN 'Directing'  THEN 3.0
          WHEN 'Writing'    THEN 1.5
          WHEN 'Production' THEN 1.0
          ELSE
            CASE WHEN mc.cast_order <= 3  THEN 2.0
                 WHEN mc.cast_order <= 10 THEN 1.5
                 ELSE 1.0
            END
        END) DESC
      LIMIT 10
    ) top_talent
    """

    person_quality =
      case Repo.query(person_query, [movie.id]) do
        {:ok, %{rows: [[avg]]}} -> normalize_number(avg) || 0.0
        _ -> 0.0
      end

    # Calculate component scores (0-10 scale)
    mob = calculate_mob_score(metrics)
    critics = calculate_critics_score(metrics)
    festival_recognition = calculate_festival_recognition(festival_data)
    time_machine = calculate_time_machine_score(movie, metrics)
    # Convert from 0-100 to 0-10
    auteurs_score = person_quality / 10.0
    # Calculate box office score
    box_office = calculate_box_office_score(metrics)

    # Calculate overall score using Cinegraph Editorial weights
    weights = get_editorial_weights(ScoringService.get_profile("Cinegraph Editorial"))

    overall =
      mob * weights.mob +
        critics * weights.critics +
        festival_recognition * weights.festival_recognition +
        time_machine * weights.time_machine +
        auteurs_score * weights.auteurs +
        box_office * weights.box_office

    %{
      overall_score: Float.round(overall, 1),
      score_confidence: calculate_score_confidence(metrics),
      components: %{
        mob: Float.round(mob, 1),
        critics: Float.round(critics, 1),
        festival_recognition: Float.round(festival_recognition, 1),
        time_machine: Float.round(time_machine, 1),
        auteurs: Float.round(auteurs_score, 1),
        box_office: Float.round(box_office, 1)
      },
      raw_metrics: metrics
    }
  end

  @doc """
  Calculate mob score (audience): IMDb + TMDb ratings, null-aware averaging.
  Returns a 0–10 score.
  """
  def calculate_mob_score(metrics) do
    imdb = Map.get(metrics, :imdb_rating)
    tmdb = Map.get(metrics, :tmdb_rating)

    sources = [imdb, tmdb] |> Enum.reject(&is_nil/1) |> Enum.filter(&(&1 > 0))

    if sources == [], do: 0.0, else: Enum.sum(sources) / length(sources)
  end

  @doc """
  Calculate critics score: RT Tomatometer + Metacritic, null-aware averaging.
  Returns a 0–10 score (normalizes from 0–100 sources).
  """
  def calculate_critics_score(metrics) do
    rt = Map.get(metrics, :rt_tomatometer)
    mc = Map.get(metrics, :metacritic)

    sources =
      [{rt, 100.0}, {mc, 100.0}]
      |> Enum.reject(fn {v, _} -> is_nil(v) or v == 0 end)
      |> Enum.map(fn {v, scale} -> v / scale * 10.0 end)

    if sources == [], do: 0.0, else: Enum.sum(sources) / length(sources)
  end

  @doc """
  Calculate score confidence: fraction of the 4 core rating sources present (0.0–1.0).
  """
  def calculate_score_confidence(metrics) do
    keys = [:imdb_rating, :tmdb_rating, :rt_tomatometer, :metacritic]

    present =
      Enum.count(keys, fn k ->
        v = Map.get(metrics, k)
        not is_nil(v) and v != 0
      end)

    present / 4.0
  end

  defp get_editorial_weights(nil) do
    Lenses.default_atom_weights()
  end

  defp get_editorial_weights(profile) do
    ScoringService.profile_to_discovery_weights(profile)
  end

  @doc """
  Calculate festival recognition based on festival wins and nominations.
  """
  def calculate_festival_recognition(nomination_rows) do
    FestivalPrestige.score_nominations(nomination_rows, 10.0)
  end

  @doc """
  Calculate time machine score based on canonical sources and popularity.
  """
  def calculate_time_machine_score(movie, metrics) do
    # Check canonical sources
    canonical_count =
      if movie.canonical_sources && map_size(movie.canonical_sources) > 0 do
        map_size(movie.canonical_sources)
      else
        0
      end

    # Check popularity
    popularity = Map.get(metrics, :popularity, 0) || 0

    popularity_score =
      if popularity > 0 do
        # Normalize on log scale
        :math.log(popularity + 1) / :math.log(1000)
      else
        0
      end

    # Combine canonical presence and popularity
    min(10.0, canonical_count * 2.0 + popularity_score * 5.0)
  end

  @doc """
  Calculate box office score based on revenue and budget.
  Returns a score from 0-10 based on:
  - Revenue magnitude (logarithmic scale to 1B)
  - ROI when both budget and revenue are available
  """
  def calculate_box_office_score(metrics) do
    budget = Map.get(metrics, :budget, 0) || 0
    revenue = Map.get(metrics, :revenue, 0) || 0

    cond do
      # If we have both budget and revenue, calculate ROI-based score
      budget > 0 and revenue > 0 ->
        # Revenue component (60% weight): log scale normalized to 1B
        revenue_score = min(1.0, :math.log(revenue + 1) / :math.log(1_000_000_000))

        # ROI component (40% weight): revenue/budget ratio on log scale
        # Normalizes to 10x ROI = 1.0 to properly differentiate between profitability levels
        roi_ratio = revenue / budget
        roi_score = min(1.0, :math.log(roi_ratio + 1) / :math.log(11))

        # Combined score on 0-10 scale
        (revenue_score * 0.6 + roi_score * 0.4) * 10.0

      # If only revenue, use revenue magnitude
      revenue > 0 ->
        min(10.0, :math.log(revenue + 1) / :math.log(1_000_000_000) * 10.0)

      # No financial data
      true ->
        0.0
    end
  end

  @doc """
  Calculate collaboration strength based on movies and their average score.
  """
  def calculate_collaboration_strength(movies) do
    # Based on number of movies and their average score
    count = length(movies)

    avg_score =
      if count > 0 do
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

  @doc """
  Get score for a single movie (used in timeline calculations).
  """
  def get_movie_score(movie_id) do
    query = """
    SELECT AVG(value) 
    FROM external_metrics 
    WHERE movie_id = $1 
      AND source IN ('imdb', 'tmdb') 
      AND metric_type = 'rating_average'
    """

    case Repo.query(query, [movie_id]) do
      {:ok, %{rows: [[score]]}} ->
        score_val = normalize_number(score)
        if score_val, do: Float.round(score_val, 1), else: nil

      _ ->
        nil
    end
  end

  @doc """
  Explains the people_quality score for a movie.

  Returns a map with:
    - avg_top10: the average quality score of the top-10 unique people (0–100 scale)
    - unique_people: total unique people with a quality score
    - total_credits: total credit rows for this movie
    - top_people: list of {name, job, score, role_weight} for the top 10 unique people

  Usage:
    iex> Cinegraph.Movies.MovieScoring.explain_people_quality(123)
  """
  def explain_people_quality(movie_id) do
    top_query = """
    SELECT MAX(p.name) as name, MAX(mc.job) as job, MAX(pm.score) as max_score,
      MAX(CASE mc.department
        WHEN 'Directing'  THEN 3.0
        WHEN 'Writing'    THEN 1.5
        WHEN 'Production' THEN 1.0
        ELSE
          CASE WHEN mc.cast_order <= 3  THEN 2.0
               WHEN mc.cast_order <= 10 THEN 1.5
               ELSE 1.0
          END
      END) as role_weight
    FROM movie_credits mc
    JOIN person_metrics pm ON pm.person_id = mc.person_id
    JOIN people p ON p.id = mc.person_id
    WHERE mc.movie_id = $1 AND pm.metric_type = 'quality_score'
    GROUP BY mc.person_id
    ORDER BY MAX(pm.score) * MAX(CASE mc.department
        WHEN 'Directing'  THEN 3.0
        WHEN 'Writing'    THEN 1.5
        WHEN 'Production' THEN 1.0
        ELSE
          CASE WHEN mc.cast_order <= 3  THEN 2.0
               WHEN mc.cast_order <= 10 THEN 1.5
               ELSE 1.0
          END
      END) DESC
    LIMIT 10
    """

    stats_query = """
    SELECT
      COUNT(DISTINCT mc.person_id) as unique_people,
      COUNT(*) as total_credits
    FROM movie_credits mc
    WHERE mc.movie_id = $1
    """

    top_people =
      case Repo.query(top_query, [movie_id]) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [name, job, score, weight] ->
            {name, job, normalize_number(score), normalize_number(weight)}
          end)

        _ ->
          []
      end

    {unique_people, total_credits} =
      case Repo.query(stats_query, [movie_id]) do
        {:ok, %{rows: [[u, t]]}} -> {u, t}
        _ -> {0, 0}
      end

    avg_top10 =
      if top_people == [] do
        0.0
      else
        {weighted_sum, weight_sum} =
          Enum.reduce(top_people, {0.0, 0.0}, fn {_, _, score, weight}, {ws, wt} ->
            s = score || 0.0
            w = weight || 1.0
            {ws + s * w, wt + w}
          end)

        if weight_sum > 0, do: weighted_sum / weight_sum, else: 0.0
      end

    %{
      avg_top10: avg_top10,
      unique_people: unique_people,
      total_credits: total_credits,
      top_people: top_people
    }
  end
end
