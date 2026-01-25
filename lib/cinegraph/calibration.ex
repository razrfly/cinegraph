defmodule Cinegraph.Calibration do
  @moduledoc """
  Context for score calibration system.

  Manages reference lists, scoring configurations, and calibration analysis.
  Provides tools to compare Cinegraph scores against authoritative external
  rankings and tune the scoring algorithm for better correlation.
  """
  import Ecto.Query

  alias Cinegraph.Repo
  alias Cinegraph.Calibration.{ReferenceList, Reference, ScoringConfiguration}
  alias Cinegraph.Movies.Movie

  # =============================================================================
  # Reference Lists
  # =============================================================================

  @doc """
  Lists all reference lists.
  """
  def list_reference_lists do
    ReferenceList
    |> order_by([r], r.name)
    |> Repo.all()
  end

  @doc """
  Gets a reference list by ID.
  """
  def get_reference_list(id), do: Repo.get(ReferenceList, id)

  @doc """
  Gets a reference list by slug.
  """
  def get_reference_list_by_slug(slug) do
    Repo.get_by(ReferenceList, slug: slug)
  end

  @doc """
  Creates a reference list.
  """
  def create_reference_list(attrs) do
    %ReferenceList{}
    |> ReferenceList.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a reference list.
  """
  def update_reference_list(%ReferenceList{} = list, attrs) do
    list
    |> ReferenceList.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a reference list and all its references.
  """
  def delete_reference_list(%ReferenceList{} = list) do
    Repo.delete(list)
  end

  @doc """
  Creates or updates a reference list from known definitions.
  """
  def upsert_known_list(slug) do
    case Map.get(ReferenceList.known_lists(), slug) do
      nil ->
        {:error, :unknown_list}

      attrs ->
        case get_reference_list_by_slug(slug) do
          nil ->
            create_reference_list(Map.put(attrs, :slug, slug))

          existing ->
            update_reference_list(existing, attrs)
        end
    end
  end

  @doc """
  Seeds all known reference lists.
  """
  def seed_known_lists do
    ReferenceList.known_lists()
    |> Map.keys()
    |> Enum.map(&upsert_known_list/1)
  end

  # =============================================================================
  # References (individual movies in lists)
  # =============================================================================

  @doc """
  Lists references for a given reference list.
  """
  def list_references(reference_list_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 250)
    include_unmatched = Keyword.get(opts, :include_unmatched, true)

    query =
      Reference
      |> where([r], r.reference_list_id == ^reference_list_id)
      |> order_by([r], asc_nulls_last: r.rank)
      |> limit(^limit)
      |> preload(:movie)

    query =
      if include_unmatched do
        query
      else
        where(query, [r], not is_nil(r.movie_id))
      end

    Repo.all(query)
  end

  @doc """
  Gets a reference by ID.
  """
  def get_reference(id), do: Repo.get(Reference, id)

  @doc """
  Creates a reference.
  """
  def create_reference(attrs) do
    %Reference{}
    |> Reference.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a reference.
  """
  def update_reference(%Reference{} = ref, attrs) do
    ref
    |> Reference.changeset(attrs)
    |> Repo.update()
  end

  # Whitelist of allowed keys for reference imports to prevent atom table exhaustion
  @reference_allowed_keys %{
    "reference_list_id" => :reference_list_id,
    "movie_id" => :movie_id,
    "rank" => :rank,
    "external_score" => :external_score,
    "external_id" => :external_id,
    "external_title" => :external_title,
    "external_year" => :external_year,
    "match_confidence" => :match_confidence,
    "inserted_at" => :inserted_at,
    "updated_at" => :updated_at
  }

  @doc """
  Bulk imports references for a reference list.
  """
  def import_references(reference_list_id, references) when is_list(references) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    entries =
      references
      |> Enum.map(fn ref ->
        ref
        |> Map.put(:reference_list_id, reference_list_id)
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
        |> normalize_keys_to_atoms()
      end)

    Repo.insert_all(Reference, entries,
      on_conflict: {:replace, [:rank, :external_score, :updated_at]},
      conflict_target: [:reference_list_id, :movie_id]
    )
  end

  defp normalize_keys_to_atoms(map) do
    map
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      string_key = to_string(k)

      case Map.get(@reference_allowed_keys, string_key) do
        nil -> acc
        atom_key -> Map.put(acc, atom_key, v)
      end
    end)
  end

  @doc """
  Attempts to match unmatched references to movies in the database.
  Uses title and year matching with fuzzy logic.
  """
  def match_references(reference_list_id) do
    unmatched =
      Reference
      |> where([r], r.reference_list_id == ^reference_list_id)
      |> where([r], is_nil(r.movie_id))
      |> Repo.all()

    Enum.map(unmatched, fn ref ->
      case find_movie_match(ref) do
        {:ok, movie, confidence} ->
          update_reference(ref, %{movie_id: movie.id, match_confidence: confidence})

        :no_match ->
          {:ok, ref}
      end
    end)
  end

  defp find_movie_match(%Reference{external_title: title, external_year: year}) do
    # Try exact match first (case-insensitive but literal, no wildcard)
    query =
      Movie
      |> where([m], fragment("LOWER(?) = LOWER(?)", m.title, ^title))

    query =
      if year do
        where(query, [m], fragment("EXTRACT(YEAR FROM ?)", m.release_date) == ^year)
      else
        query
      end

    case Repo.one(query) do
      nil ->
        # Try fuzzy match
        find_fuzzy_match(title, year)

      movie ->
        {:ok, movie, Decimal.new("1.0")}
    end
  end

  defp find_fuzzy_match(title, year) do
    # Simplified fuzzy matching using trigram similarity
    query =
      Movie
      |> where([m], fragment("similarity(?, ?) > 0.5", m.title, ^title))
      |> order_by([m], desc: fragment("similarity(?, ?)", m.title, ^title))

    query =
      if year do
        where(
          query,
          [m],
          fragment("EXTRACT(YEAR FROM ?)", m.release_date) >= ^(year - 1) and
            fragment("EXTRACT(YEAR FROM ?)", m.release_date) <= ^(year + 1)
        )
      else
        query
      end

    case Repo.one(query |> limit(1)) do
      nil ->
        :no_match

      movie ->
        # Calculate confidence based on similarity
        similarity_query =
          from(m in Movie,
            where: m.id == ^movie.id,
            select: fragment("similarity(?, ?)", m.title, ^title)
          )

        confidence =
          case Repo.one(similarity_query) do
            nil -> Decimal.new("0.5")
            sim -> Decimal.from_float(sim)
          end

        {:ok, movie, confidence}
    end
  end

  # =============================================================================
  # Scoring Configurations
  # =============================================================================

  @doc """
  Lists all scoring configurations.
  """
  def list_scoring_configurations(opts \\ []) do
    include_drafts = Keyword.get(opts, :include_drafts, true)

    query =
      ScoringConfiguration
      |> order_by([s], desc: s.version)

    query =
      if include_drafts do
        query
      else
        where(query, [s], s.is_draft == false)
      end

    Repo.all(query)
  end

  @doc """
  Gets the currently active scoring configuration.
  """
  def get_active_configuration do
    ScoringConfiguration
    |> where([s], s.is_active == true)
    |> Repo.one()
  end

  @doc """
  Gets a scoring configuration by ID.
  """
  def get_scoring_configuration(id), do: Repo.get(ScoringConfiguration, id)

  @doc """
  Gets a scoring configuration by version number.
  """
  def get_scoring_configuration_by_version(version) do
    Repo.get_by(ScoringConfiguration, version: version)
  end

  @doc """
  Creates a new scoring configuration with the next version number.
  """
  def create_scoring_configuration(attrs) do
    next_version = get_next_version()

    attrs = Map.put(attrs, :version, next_version)

    %ScoringConfiguration{}
    |> ScoringConfiguration.changeset(attrs)
    |> Repo.insert()
  end

  defp get_next_version do
    case Repo.one(from(s in ScoringConfiguration, select: max(s.version))) do
      nil -> 1
      max -> max + 1
    end
  end

  @doc """
  Updates a scoring configuration.
  """
  def update_scoring_configuration(%ScoringConfiguration{} = config, attrs) do
    config
    |> ScoringConfiguration.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Activates a scoring configuration, deactivating any currently active one.
  """
  def activate_configuration(%ScoringConfiguration{} = config) do
    Repo.transaction(fn ->
      # Atomically deactivate all currently active configs
      from(s in ScoringConfiguration, where: s.is_active == true)
      |> Repo.update_all(set: [is_active: false])

      # Activate the new config
      config
      |> ScoringConfiguration.activate_changeset()
      |> Repo.update!()
    end)
  end

  @doc """
  Seeds the default scoring configuration if none exists.
  """
  def seed_default_configuration do
    case get_active_configuration() do
      nil ->
        create_scoring_configuration(ScoringConfiguration.default_config())

      existing ->
        {:ok, existing}
    end
  end

  # =============================================================================
  # Calibration Analysis
  # =============================================================================

  @doc """
  Calculates correlation metrics between Cinegraph scores and a reference list.

  Returns a map with:
  - :pearson_correlation - Pearson correlation coefficient (-1 to 1)
  - :spearman_correlation - Spearman rank correlation (-1 to 1)
  - :mean_absolute_error - Average absolute difference
  - :matched_count - Number of movies matched
  - :total_count - Total movies in reference list
  - :score_distribution - Distribution of Cinegraph scores for matched movies
  """
  def calculate_correlation(reference_list_id, opts \\ []) do
    config = Keyword.get(opts, :config, get_active_configuration())

    # Get matched references with scores
    matched_data = get_matched_data(reference_list_id, config)

    if length(matched_data) < 10 do
      {:error, :insufficient_data}
    else
      {:ok, compute_correlation_metrics(matched_data, reference_list_id)}
    end
  end

  defp get_matched_data(reference_list_id, _config) do
    # Subquery to calculate average rating per movie from imdb/tmdb sources
    avg_ratings_subquery =
      from(em in "external_metrics",
        where: em.source in ["imdb", "tmdb"] and em.metric_type == "rating_average",
        group_by: em.movie_id,
        select: %{movie_id: em.movie_id, avg_rating: avg(em.value)}
      )

    # Main query joining references with movies and the avg ratings
    query =
      from(r in Reference,
        join: m in Movie,
        on: r.movie_id == m.id,
        left_join: ar in subquery(avg_ratings_subquery),
        on: ar.movie_id == m.id,
        where: r.reference_list_id == ^reference_list_id,
        where: not is_nil(r.movie_id),
        where: not is_nil(r.rank),
        order_by: [asc: r.rank],
        select: %{
          rank: r.rank,
          external_score: r.external_score,
          cinegraph_score: coalesce(ar.avg_rating, 5.0)
        }
      )

    query
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        rank: row.rank,
        external_score: to_float(row.external_score),
        cinegraph_score: to_float(row.cinegraph_score)
      }
    end)
  end

  defp to_float(nil), do: nil
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n / 1.0
  defp to_float(_), do: nil

  defp compute_correlation_metrics(data, reference_list_id) do
    scores = Enum.map(data, & &1.cinegraph_score) |> Enum.filter(&(&1 != nil))
    external = Enum.map(data, & &1.external_score) |> Enum.filter(&(&1 != nil))
    ranks = Enum.map(data, & &1.rank)

    # Get total count from reference list
    total_count =
      Reference
      |> where([r], r.reference_list_id == ^reference_list_id)
      |> Repo.aggregate(:count)

    %{
      pearson_correlation: pearson_correlation(scores, external),
      spearman_correlation: spearman_correlation(scores, ranks),
      mean_absolute_error: mean_absolute_error(scores, external),
      matched_count: length(data),
      total_count: total_count,
      match_rate: length(data) / max(total_count, 1),
      score_distribution: compute_distribution(scores),
      mean_cinegraph_score: safe_mean(scores),
      mean_external_score: safe_mean(external)
    }
  end

  defp pearson_correlation(x, y) when length(x) < 2 or length(y) < 2, do: nil

  defp pearson_correlation(x, y) do
    n = min(length(x), length(y))
    x = Enum.take(x, n)
    y = Enum.take(y, n)

    mean_x = Enum.sum(x) / n
    mean_y = Enum.sum(y) / n

    numerator =
      Enum.zip(x, y)
      |> Enum.map(fn {xi, yi} -> (xi - mean_x) * (yi - mean_y) end)
      |> Enum.sum()

    sum_sq_x = x |> Enum.map(&((&1 - mean_x) ** 2)) |> Enum.sum()
    sum_sq_y = y |> Enum.map(&((&1 - mean_y) ** 2)) |> Enum.sum()

    denominator = :math.sqrt(sum_sq_x * sum_sq_y)

    if denominator == 0, do: nil, else: Float.round(numerator / denominator, 4)
  end

  defp spearman_correlation(scores, _ranks) when length(scores) < 2, do: nil

  defp spearman_correlation(scores, ranks) do
    # Convert scores to ranks
    score_ranks =
      scores
      |> Enum.with_index(1)
      |> Enum.sort_by(fn {score, _idx} -> -score end)
      |> Enum.with_index(1)
      |> Enum.map(fn {{_score, orig_idx}, new_rank} -> {orig_idx, new_rank} end)
      |> Enum.sort_by(fn {orig_idx, _} -> orig_idx end)
      |> Enum.map(fn {_, rank} -> rank end)

    # Pearson on ranks
    pearson_correlation(score_ranks, ranks)
  end

  defp mean_absolute_error(x, y) when length(x) < 1 or length(y) < 1, do: nil

  defp mean_absolute_error(x, y) do
    n = min(length(x), length(y))
    x = Enum.take(x, n)
    y = Enum.take(y, n)

    Enum.zip(x, y)
    |> Enum.map(fn {xi, yi} -> abs(xi - yi) end)
    |> Enum.sum()
    |> Kernel./(n)
    |> Float.round(4)
  end

  defp compute_distribution(scores) do
    buckets = %{
      "0-2" => 0,
      "2-4" => 0,
      "4-6" => 0,
      "6-8" => 0,
      "8-10" => 0
    }

    Enum.reduce(scores, buckets, fn score, acc ->
      bucket =
        cond do
          score < 2 -> "0-2"
          score < 4 -> "2-4"
          score < 6 -> "4-6"
          score < 8 -> "6-8"
          true -> "8-10"
        end

      Map.update!(acc, bucket, &(&1 + 1))
    end)
  end

  defp safe_mean([]), do: nil

  defp safe_mean(list) do
    Float.round(Enum.sum(list) / length(list), 2)
  end

  @doc """
  Gets top mismatches - movies where Cinegraph score differs significantly from external score.
  """
  def get_top_mismatches(reference_list_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    min_difference = Keyword.get(opts, :min_difference, 1.5)

    query = """
    WITH movie_scores AS (
      SELECT
        m.id as movie_id,
        m.title,
        m.release_date,
        COALESCE(
          (SELECT AVG(value) FROM external_metrics em
           WHERE em.movie_id = m.id
           AND em.source IN ('imdb', 'tmdb')
           AND em.metric_type = 'rating_average'),
          5.0
        ) as cinegraph_score
      FROM movies m
    )
    SELECT
      ms.movie_id,
      ms.title,
      ms.release_date,
      r.rank,
      r.external_score,
      ms.cinegraph_score,
      (r.external_score - ms.cinegraph_score) as difference
    FROM calibration_references r
    JOIN movie_scores ms ON ms.movie_id = r.movie_id
    WHERE r.reference_list_id = $1
      AND r.movie_id IS NOT NULL
      AND r.external_score IS NOT NULL
      AND ABS(r.external_score - ms.cinegraph_score) > $2
    ORDER BY ABS(r.external_score - ms.cinegraph_score) DESC
    LIMIT $3
    """

    case Repo.query(query, [reference_list_id, min_difference, limit]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [movie_id, title, release_date, rank, external, cg, diff] ->
          %{
            movie_id: movie_id,
            title: title,
            release_date: release_date,
            rank: rank,
            external_score: to_float(external),
            cinegraph_score: to_float(cg),
            difference: to_float(diff)
          }
        end)

      _ ->
        []
    end
  end

  @doc """
  Simulates what scores would look like with a different configuration.
  Returns sample movies with before/after scores.
  """
  def simulate_configuration(%ScoringConfiguration{} = config, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    reference_list_id = Keyword.get(opts, :reference_list_id)

    # Get sample of movies to simulate
    movies =
      if reference_list_id do
        Reference
        |> where([r], r.reference_list_id == ^reference_list_id)
        |> where([r], not is_nil(r.movie_id))
        |> order_by([r], asc: r.rank)
        |> limit(^limit)
        |> preload(:movie)
        |> Repo.all()
        |> Enum.map(& &1.movie)
      else
        Movie
        |> order_by(fragment("RANDOM()"))
        |> limit(^limit)
        |> Repo.all()
      end

    # Calculate scores with current and new configuration
    current_config = get_active_configuration()

    Enum.map(movies, fn movie ->
      current_score = calculate_score_for_movie(movie, current_config)
      new_score = calculate_score_for_movie(movie, config)

      %{
        movie_id: movie.id,
        title: movie.title,
        current_score: current_score,
        new_score: new_score,
        difference: Float.round(new_score - current_score, 2)
      }
    end)
  end

  defp calculate_score_for_movie(movie, nil), do: calculate_score_for_movie(movie, %{})

  defp calculate_score_for_movie(movie, config) do
    # Simplified score calculation for simulation
    weights = Map.get(config, :category_weights, %{})

    # Get component scores
    popular = get_popular_opinion_score(movie.id)
    awards = get_awards_score(movie.id)
    cultural = get_cultural_score(movie.id)
    people = get_people_score(movie.id)
    financial = get_financial_score(movie.id)

    # Apply weights and missing data strategies
    components = [
      {popular, Map.get(weights, "popular_opinion", 0.2), "popular_opinion"},
      {awards, Map.get(weights, "industry_recognition", 0.2), "industry_recognition"},
      {cultural, Map.get(weights, "cultural_impact", 0.2), "cultural_impact"},
      {people, Map.get(weights, "people_quality", 0.2), "people_quality"},
      {financial, Map.get(weights, "financial_performance", 0.2), "financial_performance"}
    ]

    strategies = Map.get(config, :missing_data_strategies) || %{}

    {total_score, total_weight} =
      Enum.reduce(components, {0, 0}, fn {score, weight, category}, {sum, w} ->
        case {score, Map.get(strategies, category, "neutral")} do
          {nil, "exclude"} ->
            {sum, w}

          {nil, "neutral"} ->
            {sum + 5.0 * weight, w + weight}

          {nil, "average"} ->
            {sum + 6.0 * weight, w + weight}

          {nil, "penalize"} ->
            {sum + 0, w + weight}

          {s, _} ->
            {sum + s * weight, w + weight}
        end
      end)

    if total_weight > 0 do
      Float.round(total_score / total_weight, 2)
    else
      5.0
    end
  end

  defp get_popular_opinion_score(movie_id) do
    query = """
    SELECT AVG(value)
    FROM external_metrics
    WHERE movie_id = $1
      AND source IN ('imdb', 'tmdb')
      AND metric_type = 'rating_average'
    """

    case Repo.query(query, [movie_id]) do
      {:ok, %{rows: [[score]]}} -> to_float(score)
      _ -> nil
    end
  end

  defp get_awards_score(movie_id) do
    query = """
    SELECT
      COUNT(CASE WHEN won THEN 1 END) * 2.0 +
      COUNT(*) * 0.5
    FROM festival_nominations
    WHERE movie_id = $1
    """

    case Repo.query(query, [movie_id]) do
      {:ok, %{rows: [[score]]}} ->
        s = to_float(score)
        if s && s > 0, do: min(10.0, s), else: nil

      _ ->
        nil
    end
  end

  defp get_cultural_score(movie_id) do
    # Simplified - uses popularity score as a proxy for cultural impact
    query = """
    SELECT value
    FROM external_metrics
    WHERE movie_id = $1
      AND source = 'tmdb'
      AND metric_type = 'popularity_score'
    LIMIT 1
    """

    case Repo.query(query, [movie_id]) do
      {:ok, %{rows: [[popularity]]}} ->
        p = to_float(popularity)
        if p && p > 0, do: min(10.0, :math.log(p + 1) / :math.log(1000) * 5), else: nil

      _ ->
        nil
    end
  end

  defp get_people_score(movie_id) do
    query = """
    SELECT AVG(pm.score) / 10.0
    FROM movie_credits mc
    JOIN person_metrics pm ON pm.person_id = mc.person_id
    WHERE mc.movie_id = $1 AND pm.metric_type = 'quality_score'
    """

    case Repo.query(query, [movie_id]) do
      {:ok, %{rows: [[score]]}} -> to_float(score)
      _ -> nil
    end
  end

  defp get_financial_score(movie_id) do
    query = """
    SELECT
      MAX(CASE WHEN metric_type = 'budget' THEN value END) as budget,
      MAX(CASE WHEN metric_type = 'revenue_worldwide' THEN value END) as revenue
    FROM external_metrics
    WHERE movie_id = $1 AND source = 'tmdb'
    """

    case Repo.query(query, [movie_id]) do
      {:ok, %{rows: [[budget, revenue]]}} ->
        b = to_float(budget)
        r = to_float(revenue)

        cond do
          b && b > 0 && r && r > 0 ->
            revenue_score = min(1.0, :math.log(r + 1) / :math.log(1_000_000_000))
            roi_score = min(1.0, :math.log(r / b + 1) / :math.log(11))
            (revenue_score * 0.6 + roi_score * 0.4) * 10

          r && r > 0 ->
            min(10.0, :math.log(r + 1) / :math.log(1_000_000_000) * 10)

          true ->
            nil
        end

      _ ->
        nil
    end
  end
end
