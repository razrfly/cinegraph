defmodule Mix.Tasks.Cinegraph.Scoring.ParityCheck do
  @moduledoc """
  Parity gate for #1036 Session 1.

  Two modes:

    * `--mode refactor` (DEFAULT, the correct gate) — for every movie, compute the
      `:absolute` lens scores BOTH the new catalog-driven way and the OLD bespoke way
      (`LensFormulas.mob/critics/...` on the old per-movie SQL), both on the SAME live
      data, and compare. This isolates the refactor from cache staleness. Expected:
      every field within ±`--tol` (default 0.1) — bounded rounding noise from the
      catalog-driven mob/critics weighted mean.

    * `--mode cache` — compare the new path against the persisted `movie_score_caches`
      baseline. NOTE: this conflates the refactor with pre-existing cache staleness
      (rows warmed before later data changes), so >0.1 diffs here are usually stale
      cache, not regressions. Use `refactor` to judge the refactor.

      mix cinegraph.scoring.parity_check                 # refactor mode (new vs old, live)
      mix cinegraph.scoring.parity_check --mode cache --against 4
  """
  use Mix.Task
  import Ecto.Query

  alias Cinegraph.Repo
  alias Cinegraph.Movies.{Movie, MovieScoreCache, MovieScoring}
  alias Cinegraph.Scoring.LensFormulas

  @shortdoc "Prove the :absolute scoring refactor changes nothing beyond rounding noise"
  @batch 1000

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [limit: :integer, against: :string, tol: :float, mode: :string]
      )

    mode = opts[:mode] || "refactor"
    baseline = opts[:against] || "4"
    tol = opts[:tol] || 0.1
    limit = opts[:limit]

    IO.puts(
      "Parity mode=#{mode}, tolerance=#{tol}#{if limit, do: " (limit #{limit})", else: ""}…"
    )

    base = movie_source(mode, baseline)
    base = if limit, do: limit(base, ^limit), else: base

    {checked, max_diff, over, hist} =
      Repo.transaction(fn -> reduce_stream(base, mode, round(tol * 10)) end, timeout: :infinity)
      |> elem(1)

    if mode == "cache" and checked == 0 do
      Mix.raise(
        "No movie_score_caches rows for calculation_version=#{baseline} — nothing to compare. " <>
          "Pick an existing baseline with --against (the current cache version may have moved on)."
      )
    end

    IO.puts(
      "\nchecked=#{checked}  max_abs_diff=#{Float.round(max_diff, 4)}  over_tol=#{length(over)}"
    )

    IO.puts("diff histogram (abs): #{inspect(hist)}")

    if over == [] do
      IO.puts("PARITY OK — every field within ±#{tol} (bounded rounding noise).")
    else
      IO.puts("PARITY FAILED — #{length(over)} field(s) exceed ±#{tol}. First 20:")
      over |> Enum.take(20) |> Enum.each(&IO.inspect/1)
      exit({:shutdown, 1})
    end
  end

  # In refactor mode we iterate all full movies; in cache mode we iterate the baseline cache.
  defp movie_source("refactor", _baseline),
    do: from(m in Movie, where: m.import_status == "full", order_by: m.id, select: m.id)

  defp movie_source("cache", baseline),
    do:
      from(c in MovieScoreCache,
        where: c.calculation_version == ^baseline,
        order_by: c.movie_id,
        select: c.movie_id
      )

  defp reduce_stream(base, mode, tol_tenths) do
    base
    |> Repo.stream(max_rows: @batch)
    |> Stream.chunk_every(@batch)
    |> Enum.reduce({0, 0.0, [], %{"0" => 0, "0.1" => 0, ">0.1" => 0}}, fn ids,
                                                                          {n, mx, over, hist} ->
      movies = from(m in Movie, where: m.id in ^ids) |> Repo.all() |> Map.new(&{&1.id, &1})
      baselines = baseline_map(mode, ids)

      {bmx, bover, bhist} =
        Enum.reduce(ids, {mx, over, hist}, fn id, acc ->
          compare(movies[id], baselines[id], mode, tol_tenths, acc)
        end)

      IO.write(".")
      {n + length(ids), bmx, bover, bhist}
    end)
  end

  defp baseline_map("cache", ids),
    do:
      from(c in MovieScoreCache, where: c.movie_id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.movie_id, &1})

  defp baseline_map("refactor", _ids), do: %{}

  defp compare(nil, _b, _mode, _tol, acc), do: acc

  defp compare(movie, baseline, mode, tol_tenths, {mx, over, hist}) do
    new = MovieScoring.calculate_movie_scores(movie)
    nc = new.components

    fields =
      case mode do
        "refactor" ->
          old = old_components(movie)

          [
            {:mob, nc.mob, old.mob},
            {:critics, nc.critics, old.critics},
            {:festival, nc.festival_recognition, old.festival_recognition},
            {:time_machine, nc.time_machine, old.time_machine},
            {:auteurs, nc.auteurs, old.auteurs},
            {:box_office, nc.box_office, old.box_office}
          ]

        "cache" ->
          [
            {:mob, nc.mob, baseline && baseline.mob_score},
            {:critics, nc.critics, baseline && baseline.critics_score},
            {:festival, nc.festival_recognition, baseline && baseline.festival_recognition_score},
            {:time_machine, nc.time_machine, baseline && baseline.time_machine_score},
            {:auteurs, nc.auteurs, baseline && baseline.auteurs_score},
            {:box_office, nc.box_office, baseline && baseline.box_office_score},
            {:overall, new.overall_score, baseline && baseline.overall_score}
          ]
      end

    Enum.reduce(fields, {mx, over, hist}, fn {k, a, b}, {m, ov, h} ->
      d = abs(round(num(a) * 10) - round(num(b) * 10))
      h = Map.update!(h, bucket(d), &(&1 + 1))
      ov = if d > tol_tenths, do: [{movie.id, {k, num(a), num(b)}} | ov], else: ov
      {max(m, d / 10), ov, h}
    end)
  end

  # Faithful pre-refactor :absolute computation (old per-movie pivot + bespoke formulas),
  # run on CURRENT data so the comparison is refactor-only (no cache staleness).
  defp old_components(movie) do
    metrics = old_pivot(movie.id)

    canonical =
      if movie.canonical_sources && map_size(movie.canonical_sources) > 0,
        do: map_size(movie.canonical_sources),
        else: 0

    %{
      mob: LensFormulas.mob(metrics, :absolute),
      critics: LensFormulas.critics(metrics, :absolute),
      festival_recognition: LensFormulas.festival(old_festival(movie.id), :absolute),
      time_machine:
        LensFormulas.time_machine(
          %{canonical_count: canonical, popularity: Map.get(metrics, :popularity, 0) || 0},
          :absolute
        ),
      auteurs: LensFormulas.auteurs(%{person_quality: old_person_quality(movie.id)}, :absolute),
      box_office: LensFormulas.box_office(metrics, :absolute)
    }
  end

  defp old_pivot(movie_id) do
    q = """
    SELECT
      MAX(CASE WHEN source='imdb' AND metric_type='rating_average' THEN value END),
      MAX(CASE WHEN source='tmdb' AND metric_type='rating_average' THEN value END),
      MAX(CASE WHEN source='metacritic' AND metric_type='metascore' THEN value END),
      MAX(CASE WHEN source='rotten_tomatoes' AND metric_type='tomatometer' THEN value END),
      MAX(CASE WHEN source='tmdb' AND metric_type='popularity_score' THEN value END),
      MAX(CASE WHEN source='tmdb' AND metric_type='budget' THEN value END),
      MAX(CASE WHEN source='tmdb' AND metric_type='revenue_worldwide' THEN value END)
    FROM external_metrics WHERE movie_id=$1
    """

    {:ok, %{rows: [[im, tm, mc, rt, pop, bud, rev]]}} = Repo.query(q, [movie_id])
    f = &MovieScoring.normalize_number/1

    %{
      imdb_rating: f.(im),
      tmdb_rating: f.(tm),
      metacritic: f.(mc),
      rt_tomatometer: f.(rt),
      popularity: f.(pop),
      budget: f.(bud),
      revenue: f.(rev)
    }
  end

  defp old_festival(movie_id) do
    q = """
    SELECT fo.abbreviation, fc.name, fnom.won, fo.win_score, fo.nom_score
    FROM festival_nominations fnom
    JOIN festival_categories fc ON fnom.category_id = fc.id
    JOIN festival_ceremonies fcer ON fnom.ceremony_id = fcer.id
    JOIN festival_organizations fo ON fcer.organization_id = fo.id
    WHERE fnom.movie_id = $1
    """

    case Repo.query(q, [movie_id]) do
      {:ok, %{rows: rows}} -> rows
      _ -> []
    end
  end

  defp old_person_quality(movie_id) do
    q = """
    SELECT SUM(max_score * role_weight) / NULLIF(SUM(role_weight), 0)
    FROM (
      SELECT mc.person_id, MAX(pm.score) as max_score,
        MAX(CASE mc.department WHEN 'Directing' THEN 3.0 WHEN 'Writing' THEN 1.5 WHEN 'Production' THEN 1.0
          ELSE CASE WHEN mc.cast_order <= 3 THEN 2.0 WHEN mc.cast_order <= 10 THEN 1.5 ELSE 1.0 END END) as role_weight
      FROM movie_credits mc JOIN person_metrics pm ON pm.person_id = mc.person_id
      WHERE mc.movie_id = $1 AND pm.metric_type = 'quality_score'
      GROUP BY mc.person_id
      ORDER BY MAX(pm.score) * MAX(CASE mc.department WHEN 'Directing' THEN 3.0 WHEN 'Writing' THEN 1.5 WHEN 'Production' THEN 1.0
          ELSE CASE WHEN mc.cast_order <= 3 THEN 2.0 WHEN mc.cast_order <= 10 THEN 1.5 ELSE 1.0 END END) DESC
      LIMIT 10
    ) t
    """

    case Repo.query(q, [movie_id]) do
      {:ok, %{rows: [[avg]]}} -> MovieScoring.normalize_number(avg) || 0.0
      _ -> 0.0
    end
  end

  defp num(nil), do: 0.0
  defp num(%Decimal{} = d), do: Decimal.to_float(d)
  defp num(x) when is_integer(x), do: x * 1.0
  defp num(x), do: x

  defp bucket(0), do: "0"
  defp bucket(1), do: "0.1"
  defp bucket(_), do: ">0.1"
end
