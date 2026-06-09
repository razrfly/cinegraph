defmodule Cinegraph.Scoring.FeatureResolver do
  @moduledoc """
  Layer 0 → Layer 1 bridge (#1036): the single place that loads a movie's normalized
  feature inputs for the lens formulas, in either scoring mode.

      mode :: :absolute | {:target, source_key}

  `:absolute` (discovery) builds the inputs `MovieScoring` historically assembled inline.
  `{:target, source_key}` (prediction) builds the inputs `LensScoring` historically
  assembled, and **encapsulates the leakage strip**: a movie's score for list `L` is
  independent of whether `L` is in its `canonical_sources`
    * `time_machine` — `source_key` removed before counting canonical lists
      (the derived `canonical_contribution{L}` feature), and
    * `auteurs` — the director track-record count excludes the movie's own membership in `L`
      (the derived `auteur_track_record{L}` feature).

  In `:absolute` mode the external inputs are loaded by **joining the `metric_definitions`
  catalog** to the movie's `external_metrics` (so adding a raw catalog row flows in with
  no code change), and the `:weighted_mean` lenses (mob/critics) get their members from
  the catalog. The `:custom` lenses read named inputs the formulas combine bespoke.

  Returns a `feature_bundle`:

      # :absolute
      %{inputs: <named inputs map>, lens_members: %{lens => [%{value, scale_max, weight}]}, festival_rows: [...]}
      # {:target, source_key}
      %{inputs: <named inputs map>, festival_rows: [...]}
  """

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Movies.MovieScoring
  alias Cinegraph.Scoring.Lenses

  # ── public API ─────────────────────────────────────────────────────────────

  @doc "Resolve a single movie's feature bundle for the given mode."
  def resolve(movie, :absolute), do: resolve_absolute(movie)

  def resolve(movie, {:target, source_key}) do
    resolve_batch([movie], {:target, source_key})
    |> Map.fetch!(movie.id)
  end

  @doc "Resolve many movies' feature bundles. Returns %{movie_id => bundle}."
  def resolve_batch(movies, :absolute) do
    Map.new(movies, fn movie -> {movie.id, resolve_absolute(movie)} end)
  end

  def resolve_batch(movies, {:target, source_key}) do
    movie_ids = Enum.map(movies, & &1.id)

    external_metrics = batch_load_external_metrics(movie_ids)
    festival_nominations = batch_load_festival_nominations(movie_ids)

    movies_on_target =
      for m <- movies,
          Map.has_key?(Map.get(m, :canonical_sources) || %{}, source_key),
          into: MapSet.new(),
          do: m.id

    director_info = batch_load_director_info(movie_ids, source_key, movies_on_target)

    Map.new(movies, fn movie ->
      bundle = %{
        inputs:
          build_target_inputs(
            movie,
            external_metrics[movie.id] || [],
            director_info[movie.id] || {0, nil},
            source_key
          ),
        festival_rows: festival_nominations[movie.id] || []
      }

      {movie.id, bundle}
    end)
  end

  # ── :absolute (discovery) — catalog-driven (#1036) ──────────────────────────
  # External inputs are loaded by joining the metric_definitions catalog to the
  # movie's external_metrics (so a new catalog row flows in with no code change).
  # :weighted_mean lenses (mob/critics) are computed from their catalog members;
  # the :custom lenses read named inputs the formulas combine bespoke.

  defp resolve_absolute(movie) do
    # One catalog-driven query returns every external data point the movie has, with
    # the catalog metadata needed to (a) feed named inputs to the :custom lenses and
    # (b) build :weighted_mean members — no per-movie membership queries.
    catalog_rows = load_catalog_external(movie.id)
    raw_values = Map.new(catalog_rows, fn r -> {r.code, r.value} end)

    festival_rows = load_absolute_festival(movie.id)
    person_quality = load_absolute_person_quality(movie.id)

    canonical_count =
      if movie.canonical_sources && map_size(movie.canonical_sources) > 0 do
        map_size(movie.canonical_sources)
      else
        0
      end

    # Named inputs for the :custom-strategy lenses + the score-confidence ratings.
    inputs = %{
      imdb_rating: raw_values["imdb_rating"],
      tmdb_rating: raw_values["tmdb_rating"],
      metacritic: raw_values["metacritic_metascore"],
      rt_tomatometer: raw_values["rotten_tomatoes_tomatometer"],
      popularity: raw_values["tmdb_popularity_score"],
      budget: raw_values["tmdb_budget"],
      revenue: raw_values["tmdb_revenue_worldwide"],
      canonical_count: canonical_count,
      person_quality: person_quality
    }

    %{
      inputs: inputs,
      lens_members: weighted_mean_members(catalog_rows),
      festival_rows: festival_rows
    }
  end

  # %{lens_atom => [%{value, scale_max, weight}]} for the :weighted_mean lenses, built
  # from the joined catalog rows (only members with data appear — exactly the set
  # weighted_mean counts as present).
  defp weighted_mean_members(catalog_rows) do
    wm = Lenses.weighted_mean_lenses() |> Enum.map(&to_string/1) |> MapSet.new()

    grouped =
      catalog_rows
      |> Enum.filter(&MapSet.member?(wm, &1.category))
      |> Enum.group_by(& &1.category, fn r ->
        %{value: r.value, scale_max: r.scale_max, weight: r.weight}
      end)

    Map.new(Lenses.weighted_mean_lenses(), fn lens ->
      {lens, Map.get(grouped, to_string(lens), [])}
    end)
  end

  defp load_catalog_external(movie_id) do
    query = """
    SELECT md.code, md.category, md.weight_within_lens, md.raw_scale_max, em.value
    FROM metric_definitions md
    JOIN external_metrics em
      ON em.source = md.source_type AND em.metric_type = md.source_field
    WHERE md.active = true
      AND md.kind = 'raw'
      AND md.source_table = 'external_metrics'
      AND md.source_type IS NOT NULL
      AND md.source_field IS NOT NULL
      AND em.movie_id = $1
    """

    case Repo.query(query, [movie_id]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [code, category, weight, scale_max, value] ->
          %{
            code: code,
            category: category,
            weight: weight,
            scale_max: scale_max,
            value: MovieScoring.normalize_number(value)
          }
        end)

      _ ->
        []
    end
  end

  defp load_absolute_festival(movie_id) do
    festival_query = """
    SELECT fo.abbreviation, fc.name, fnom.won, fo.win_score, fo.nom_score
    FROM festival_nominations fnom
    JOIN festival_categories fc ON fnom.category_id = fc.id
    JOIN festival_ceremonies fcer ON fnom.ceremony_id = fcer.id
    JOIN festival_organizations fo ON fcer.organization_id = fo.id
    WHERE fnom.movie_id = $1
    """

    case Repo.query(festival_query, [movie_id]) do
      {:ok, %{rows: rows}} -> rows
      _ -> []
    end
  end

  defp load_absolute_person_quality(movie_id) do
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

    case Repo.query(person_query, [movie_id]) do
      {:ok, %{rows: [[avg]]}} -> MovieScoring.normalize_number(avg) || 0.0
      _ -> 0.0
    end
  end

  # ── {:target, source_key} (prediction) — relocated verbatim from LensScoring ─

  defp build_target_inputs(
         movie,
         ext_metrics,
         {director_target_count, director_avg_imdb},
         source_key
       ) do
    # Strip the target list before counting canonical presence (leakage guard) —
    # the derived canonical_contribution{source_key} feature.
    canonical_count =
      (Map.get(movie, :canonical_sources) || %{})
      |> Map.delete(source_key)
      |> map_size()

    %{
      imdb_rating: target_metric(ext_metrics, "imdb", "rating_average"),
      tmdb_rating: target_metric(ext_metrics, "tmdb", "rating_average"),
      imdb_votes: target_metric(ext_metrics, "imdb", "rating_votes") || 0.0,
      metacritic: target_metric(ext_metrics, "metacritic", "metascore"),
      rt_tomatometer: target_metric(ext_metrics, "rotten_tomatoes", "tomatometer"),
      canonical_count: canonical_count,
      release_year: movie_release_year(movie),
      # Budget/revenue from the catalogued external-metrics (same source absolute uses), NOT the
      # raw `tmdb_data` blob (#1042). Coverage matches the blob — both come from TMDb's numbers.
      tmdb_budget: target_metric(ext_metrics, "tmdb", "budget") || 0,
      tmdb_revenue: target_metric(ext_metrics, "tmdb", "revenue_worldwide") || 0,
      # Raw commercial/popularity magnitudes for the #1087 band (one-hot) features — surfaced here so
      # DerivedFeatures can bin them from real dollars/counts (NOT the normalized view). nil = absent
      # → the band loader emits the explicit `*_missing` bin (distinct from "scored low").
      omdb_revenue_domestic: target_metric(ext_metrics, "omdb", "revenue_domestic"),
      tmdb_votes: target_metric(ext_metrics, "tmdb", "rating_votes"),
      tmdb_popularity: target_metric(ext_metrics, "tmdb", "popularity_score"),
      director_target_count: director_target_count,
      director_avg_imdb: director_avg_imdb
    }
  end

  defp target_metric(ext_metrics, source, metric_type) do
    Enum.find_value(ext_metrics, fn
      [^source, ^metric_type, value] -> value
      _ -> nil
    end)
  end

  defp movie_release_year(%{release_date: %Date{year: y}}), do: y
  defp movie_release_year(_), do: 2000

  defp batch_by_chunks(movie_ids, query_fn, chunk_size \\ 500) do
    movie_ids
    |> Enum.chunk_every(chunk_size)
    |> Enum.reduce(%{}, fn chunk_ids, acc -> Map.merge(acc, query_fn.(chunk_ids)) end)
  end

  defp batch_load_external_metrics(movie_ids) do
    batch_by_chunks(movie_ids, fn chunk_ids ->
      from(em in "external_metrics",
        where: em.movie_id in ^chunk_ids,
        select: [em.movie_id, em.source, em.metric_type, em.value]
      )
      |> Repo.all(timeout: :timer.seconds(30))
      |> Enum.group_by(&hd/1, fn [_movie_id, source, metric_type, value] ->
        [source, metric_type, value]
      end)
    end)
  end

  defp batch_load_festival_nominations(movie_ids) do
    batch_by_chunks(movie_ids, fn chunk_ids ->
      from(fnom in "festival_nominations",
        join: fc in "festival_categories",
        on: fnom.category_id == fc.id,
        join: fcer in "festival_ceremonies",
        on: fnom.ceremony_id == fcer.id,
        join: fo in "festival_organizations",
        on: fcer.organization_id == fo.id,
        where: fnom.movie_id in ^chunk_ids,
        select: [
          fnom.movie_id,
          fo.abbreviation,
          fc.name,
          fnom.won,
          fcer.year,
          fo.win_score,
          fo.nom_score
        ]
      )
      |> Repo.all(timeout: :timer.seconds(30))
      |> Enum.group_by(&hd/1, fn [_movie_id, festival, category, won, year, win_score, nom_score] ->
        [festival, category, won, year, win_score, nom_score]
      end)
    end)
  end

  # Returns %{movie_id => {director_target_count, director_avg_imdb}} where the count
  # excludes the movie's own membership in `source_key` (leakage guard for `auteurs`).
  defp batch_load_director_info(movie_ids, source_key, movies_on_target) do
    director_map =
      batch_by_chunks(movie_ids, fn chunk_ids ->
        from(mc in "movie_credits",
          where: mc.movie_id in ^chunk_ids,
          where: mc.credit_type == "crew",
          where: mc.department == "Directing",
          select: [mc.movie_id, mc.person_id]
        )
        |> Repo.all(timeout: :timer.seconds(30))
        |> Enum.group_by(&hd/1, fn [_movie_id, person_id] -> person_id end)
      end)

    all_director_ids = director_map |> Map.values() |> List.flatten() |> Enum.uniq()

    director_target_counts = director_target_counts(all_director_ids, source_key)
    director_avg_ratings = director_avg_ratings(all_director_ids)

    Map.new(director_map, fn {movie_id, director_ids} ->
      raw_count =
        director_ids
        |> Enum.map(&Map.get(director_target_counts, &1, 0))
        |> Enum.sum()

      # Exclude this movie's own contribution to its directors' counts.
      self_adjust =
        if MapSet.member?(movies_on_target, movie_id), do: length(director_ids), else: 0

      target_count = max(raw_count - self_adjust, 0)

      avg_imdb =
        director_ids
        |> Enum.map(&Map.get(director_avg_ratings, &1))
        |> Enum.reject(&is_nil/1)
        |> then(fn ratings ->
          if ratings == [], do: nil, else: Enum.sum(ratings) / length(ratings)
        end)

      {movie_id, {target_count, avg_imdb}}
    end)
  end

  defp director_target_counts([], _source_key), do: %{}

  defp director_target_counts(director_ids, source_key) do
    director_ids
    |> Enum.chunk_every(500)
    |> Enum.reduce(%{}, fn chunk_ids, acc ->
      rows =
        from(m in Movie,
          join: mc in "movie_credits",
          on: m.id == mc.movie_id,
          where: fragment("? \\? ?", m.canonical_sources, ^source_key),
          where: mc.person_id in ^chunk_ids,
          where: mc.credit_type == "crew",
          where: mc.department == "Directing",
          group_by: mc.person_id,
          select: {mc.person_id, count()}
        )
        |> Repo.all(timeout: :timer.seconds(30))
        |> Map.new()

      Map.merge(acc, rows)
    end)
  end

  defp director_avg_ratings([]), do: %{}

  defp director_avg_ratings(director_ids) do
    director_ids
    |> Enum.chunk_every(500)
    |> Enum.reduce(%{}, fn chunk_ids, acc ->
      rows =
        from(mc in "movie_credits",
          join: em in "external_metrics",
          on: em.movie_id == mc.movie_id,
          where: em.source == "imdb",
          where: em.metric_type == "rating_average",
          where: mc.person_id in ^chunk_ids,
          where: mc.credit_type == "crew",
          where: mc.department == "Directing",
          group_by: mc.person_id,
          select: {mc.person_id, avg(em.value)}
        )
        |> Repo.all(timeout: :timer.seconds(30))
        |> Map.new(fn {id, avg_val} -> {id, to_rounded_float(avg_val)} end)

      Map.merge(acc, rows)
    end)
  end

  defp to_rounded_float(nil), do: nil
  defp to_rounded_float(%Decimal{} = d), do: d |> Decimal.to_float() |> Float.round(2)
  defp to_rounded_float(f) when is_float(f), do: Float.round(f, 2)
  defp to_rounded_float(i) when is_integer(i), do: Float.round(i * 1.0, 2)
end
