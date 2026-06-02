defmodule Cinegraph.Movies.MovieScoring do
  @moduledoc """
  Business logic for calculating movie scores and related metrics.
  Extracted from LiveView to improve separation of concerns.
  """

  import Ecto.Query

  alias Cinegraph.Movies.ExternalMetric
  alias Cinegraph.Repo
  alias Cinegraph.Scoring.{FeatureResolver, LensFormulas, Lenses}
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
    # Layer 0 → Layer 1 (#1036): the FeatureResolver loads inputs from the catalog;
    # mob/critics are catalog-driven weighted means of their members, the rest are the
    # bespoke :custom formulas. Output is byte-stable vs the prior path.
    %{inputs: inputs, lens_members: lens_members, festival_rows: festival_data} =
      FeatureResolver.resolve(movie, :absolute)

    # Calculate component scores (0-10 scale)
    mob = LensFormulas.weighted_mean(lens_members.mob)
    critics = LensFormulas.weighted_mean(lens_members.critics)
    festival_recognition = LensFormulas.festival(festival_data, :absolute)
    time_machine = LensFormulas.time_machine(inputs, :absolute)
    # Intrinsic person quality (0-100) → auteurs lens on 0-10 scale
    auteurs_score = LensFormulas.auteurs(inputs, :absolute)
    # Calculate box office score
    box_office = LensFormulas.box_office(inputs, :absolute)

    # Calculate overall score using Cinegraph Editorial weights
    weights = get_editorial_weights(ScoringService.get_profile("Cinegraph Editorial"))

    overall =
      (mob || 0.0) * weights.mob +
        (critics || 0.0) * weights.critics +
        festival_recognition * weights.festival_recognition +
        time_machine * weights.time_machine +
        auteurs_score * weights.auteurs +
        box_office * weights.box_office

    %{
      overall_score: Float.round(overall, 1),
      score_confidence: calculate_score_confidence(inputs),
      components: %{
        mob: mob && Float.round(mob, 1),
        critics: critics && Float.round(critics, 1),
        festival_recognition: Float.round(festival_recognition, 1),
        time_machine: Float.round(time_machine, 1),
        auteurs: Float.round(auteurs_score, 1),
        box_office: Float.round(box_office, 1)
      },
      # Preserve the prior raw_metrics shape (the external-metrics pivot only).
      raw_metrics: Map.drop(inputs, [:canonical_count, :person_quality])
    }
  end

  @doc """
  Calculate mob score (audience): IMDb + TMDb ratings, null-aware averaging.
  Returns a 0–10 score.
  """
  def calculate_mob_score(metrics) do
    LensFormulas.mob(metrics, :absolute)
  end

  @doc """
  Calculate critics score: RT Tomatometer + Metacritic, null-aware averaging.
  Returns a 0–10 score (normalizes from 0–100 sources).
  """
  def calculate_critics_score(metrics) do
    LensFormulas.critics(metrics, :absolute)
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
    LensFormulas.festival(nomination_rows, :absolute)
  end

  @doc """
  Calculate time machine score based on canonical sources and popularity.
  """
  def calculate_time_machine_score(movie, metrics) do
    canonical_count =
      if movie.canonical_sources && map_size(movie.canonical_sources) > 0 do
        map_size(movie.canonical_sources)
      else
        0
      end

    LensFormulas.time_machine(
      %{canonical_count: canonical_count, popularity: Map.get(metrics, :popularity, 0) || 0},
      :absolute
    )
  end

  @doc """
  Calculate box office score based on revenue and budget.
  Returns a score from 0-10 based on:
  - Revenue magnitude (logarithmic scale to 1B)
  - ROI when both budget and revenue are available
  """
  def calculate_box_office_score(metrics) do
    LensFormulas.box_office(metrics, :absolute)
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
  Gets audience rating scores for multiple movies in one query.

  Returns a map of `movie_id => score` using the same IMDb/TMDb average and
  normalization as `get_movie_score/1`.
  """
  def get_movie_scores(movie_ids) when is_list(movie_ids) do
    movie_ids = movie_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if movie_ids == [] do
      %{}
    else
      query =
        ExternalMetric
        |> where([em], em.movie_id in ^movie_ids)
        |> where([em], em.source in ["imdb", "tmdb"])
        |> where([em], em.metric_type == "rating_average")
        |> group_by([em], em.movie_id)
        |> select([em], {em.movie_id, avg(em.value)})

      repo = if Repo.in_transaction?(), do: Repo, else: Repo.replica()

      query
      |> repo.all()
      |> Map.new(fn {movie_id, score} ->
        score_val = normalize_number(score)
        {movie_id, if(score_val, do: Float.round(score_val, 1), else: nil)}
      end)
    end
  end

  @doc """
  Explains the auteurs score for a movie.

  Returns a map with:
    - avg_top10: the average quality score of the top-10 unique people (0–100 scale)
    - unique_people: total unique people with a quality score
    - total_credits: total credit rows for this movie
    - top_people: list of {name, job, score, role_weight} for the top 10 unique people

  Usage:
    iex> Cinegraph.Movies.MovieScoring.explain_auteurs_score(123)
  """
  def explain_auteurs_score(movie_id) do
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
