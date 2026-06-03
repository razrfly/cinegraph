defmodule Mix.Tasks.Predictions.AuditCoverage do
  @moduledoc """
  Per-decade data completeness audit for all candidate movies (import_status = 'full').

  Shows where scoring is degraded by missing IMDb, RT, Metacritic, and festival data.

  ## Usage

      mix predictions.audit_coverage
      mix predictions.audit_coverage --decade 1960
      mix predictions.audit_coverage --json

  ## Options

    * `--decade` - audit a single decade (e.g. 1960 for 1960s)
    * `--json` - output raw JSON instead of formatted table

  """
  use Mix.Task
  import Ecto.Query

  @shortdoc "Data completeness audit by decade for candidate movies"

  @decades 1920..2020//10

  # Key objective features for the confound view; the OMDb-sourced ones get a fetch_attempt split.
  @confound_codes ~w(imdb_rating tmdb_rating metacritic_metascore rotten_tomatoes_tomatometer
                     imdb_rating_votes tmdb_budget tmdb_revenue_worldwide)
  @omdb_codes ~w(metacritic_metascore rotten_tomatoes_tomatometer)

  @impl Mix.Task
  def run(args) do
    Cinegraph.Predictions.TaskSupport.start_lean()

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          decade: :integer,
          json: :boolean,
          by_code: :boolean,
          source_key: :string
        ]
      )

    json? = Keyword.get(opts, :json, false)

    cond do
      Keyword.get(opts, :by_code, false) -> run_by_code(json?)
      Keyword.get(opts, :source_key) -> run_source_key(Keyword.fetch!(opts, :source_key), json?)
      true -> run_decades(opts, json?)
    end
  end

  # ── mode: per-decade (original behaviour) ──────────────────────────────────────
  defp run_decades(opts, json?) do
    decade_filter = Keyword.get(opts, :decade)

    decades =
      if decade_filter, do: [decade_filter], else: Enum.to_list(@decades)

    unless json?, do: Mix.shell().info("Auditing data coverage by decade...")

    results = Enum.map(decades, &fetch_decade_coverage/1)

    if json? do
      output = %{
        "task" => "predictions.audit_coverage",
        "mode" => "decade",
        "timestamp" => format_timestamp(),
        "decades" =>
          Enum.map(results, fn r ->
            %{
              "decade" => r.decade,
              "label" => r.label,
              "total_candidates" => r.total,
              "has_imdb_pct" => r.has_imdb_pct,
              "has_rt_pct" => r.has_rt_pct,
              "has_metacritic_pct" => r.has_metacritic_pct,
              "has_festivals_pct" => r.has_festivals_pct,
              "avg_festival_nominations" => r.avg_nominations,
              "low_coverage" => r.low_coverage
            }
          end)
      }

      IO.puts(Jason.encode!(output, pretty: true))
    else
      print_coverage(results)
    end
  end

  # ── mode: per-metric_code coverage (full population + global candidate universe) ──
  # The headline sparsity view (#1051): how populated each feature code is over all `full`
  # movies, and over the global scored universe (members of any list ∪ vote-gated non-members).
  defp run_by_code(json?) do
    unless json?,
      do: Mix.shell().info("Auditing per-metric_code coverage (this scans the view)...")

    full_total =
      Cinegraph.Repo.aggregate(from(m in "movies", where: m.import_status == "full"), :count)

    full_counts = code_counts_full()

    {members, negs} = Cinegraph.Predictions.CandidateUniverse.global_ids()
    universe = members ++ negs
    universe_counts = code_counts_for(universe)
    universe_total = length(universe)

    # Union in every catalogued, view-emittable (raw, available) code so a feature that is
    # catalogued but absent EVERYWHERE shows up as 0.0% rather than vanishing from the report —
    # that absence is exactly the surface gap this audit is meant to surface (CodeRabbit #1054).
    catalogued =
      Cinegraph.Metrics.list_metric_definitions(only_available: true, kind: "raw")
      |> Enum.map(& &1.code)

    codes =
      (Map.keys(full_counts) ++ Map.keys(universe_counts) ++ catalogued) |> Enum.uniq()

    rows =
      codes
      |> Enum.map(fn code ->
        %{
          code: code,
          full_pct: pct(Map.get(full_counts, code, 0), full_total),
          universe_pct: pct(Map.get(universe_counts, code, 0), universe_total)
        }
      end)
      |> Enum.sort_by(& &1.full_pct)

    if json? do
      IO.puts(
        Jason.encode!(
          %{
            "task" => "predictions.audit_coverage",
            "mode" => "by_code",
            "timestamp" => format_timestamp(),
            "full_total" => full_total,
            "universe_total" => universe_total,
            "codes" =>
              Enum.map(
                rows,
                &%{
                  "code" => &1.code,
                  "full_pct" => &1.full_pct,
                  "universe_pct" => &1.universe_pct
                }
              )
          },
          pretty: true
        )
      )
    else
      Mix.shell().info("""

      PER-CODE COVERAGE — full=#{full_total} movies, candidate universe=#{universe_total}
      #{String.duplicate("-", 60)}
      metric_code                          full%   universe%
      #{String.duplicate("-", 60)}
      """)

      Enum.each(rows, fn r ->
        Mix.shell().info(
          "#{String.pad_trailing(r.code, 36)}#{String.pad_leading("#{r.full_pct}%", 6)}  #{String.pad_leading("#{r.universe_pct}%", 9)}"
        )
      end)

      Mix.shell().info("")
    end
  end

  # ── mode: per-list candidate-universe coverage + member/non-member confound ──────
  defp run_source_key(source_key, json?) do
    {members, negs} = Cinegraph.Predictions.CandidateUniverse.ids_for(source_key)

    if members == [] do
      # Fail hard (non-zero exit, stderr) regardless of --json, so automation never sees a
      # success exit or non-JSON stdout for a bad source_key (CodeRabbit #1054).
      Mix.raise("No members found for source_key=#{source_key}")
    else
      member_sets = member_code_sets(members, @confound_codes)
      neg_counts = code_counts_for(negs, @confound_codes)
      # "fetched" = the movie has an OMDb row at all (success or fetch_attempt). For an
      # OMDb-sourced field, a member that's been fetched but still lacks the field has a
      # genuinely source-absent value (OMDb has no metascore/RT for it), as opposed to a
      # member that was simply never fetched.
      fetched = omdb_fetched_set(members)
      member_set = MapSet.new(members)

      rows =
        Enum.map(@confound_codes, fn code ->
          have_set = Map.get(member_sets, code, MapSet.new())
          have = MapSet.size(have_set)
          missing_set = MapSet.difference(member_set, have_set)
          missing = MapSet.size(missing_set)

          src_absent =
            if code in @omdb_codes,
              do: MapSet.size(MapSet.intersection(missing_set, fetched)),
              else: nil

          %{
            code: code,
            member_pct: pct(have, length(members)),
            nonmember_pct: pct(Map.get(neg_counts, code, 0), length(negs)),
            missing_members: missing,
            # of the missing members, how many were tried-and-empty (source-absent) vs never fetched
            source_absent_members: src_absent
          }
        end)

      if json? do
        IO.puts(
          Jason.encode!(
            %{
              "task" => "predictions.audit_coverage",
              "mode" => "source_key",
              "source_key" => source_key,
              "timestamp" => format_timestamp(),
              "members" => length(members),
              "non_member_candidates" => length(negs),
              "features" =>
                Enum.map(rows, fn r ->
                  %{
                    "code" => r.code,
                    "member_pct" => r.member_pct,
                    "nonmember_pct" => r.nonmember_pct,
                    "missing_members" => r.missing_members,
                    "source_absent_members" => r.source_absent_members
                  }
                end)
            },
            pretty: true
          )
        )
      else
        Mix.shell().info("""

        CANDIDATE-UNIVERSE COVERAGE — #{source_key}
        members=#{length(members)}  non-member candidates=#{length(negs)}
        #{String.duplicate("-", 72)}
        feature                          member%  nonmem%   (confound = nonmem >> member)
        #{String.duplicate("-", 72)}
        """)

        Enum.each(rows, fn r ->
          flag = if r.nonmember_pct - r.member_pct >= 20.0, do: " ⚠confound", else: ""

          Mix.shell().info(
            "#{String.pad_trailing(r.code, 32)}#{String.pad_leading("#{r.member_pct}%", 7)}  #{String.pad_leading("#{r.nonmember_pct}%", 7)}#{flag}"
          )
        end)

        Mix.shell().info(
          "\n(⚠confound = non-members have ≥20pts more coverage — \"missing data\" itself signals canon)\n"
        )
      end
    end
  end

  # %{metric_code => distinct movies with a non-null normalized_value} over a given id set.
  defp code_counts_for(ids, codes \\ nil)
  defp code_counts_for([], _codes), do: %{}

  defp code_counts_for(ids, codes) do
    {sql, params} =
      if codes do
        {"""
         SELECT metric_code, COUNT(DISTINCT movie_id)
         FROM metric_values_view
         WHERE movie_id = ANY($1) AND metric_code = ANY($2) AND normalized_value IS NOT NULL
         GROUP BY metric_code
         """, [ids, codes]}
      else
        {"""
         SELECT metric_code, COUNT(DISTINCT movie_id)
         FROM metric_values_view
         WHERE movie_id = ANY($1) AND normalized_value IS NOT NULL
         GROUP BY metric_code
         """, [ids]}
      end

    %{rows: rows} = Cinegraph.Repo.query!(sql, params, timeout: :timer.seconds(120))
    Map.new(rows, fn [code, count] -> {code, count} end)
  end

  # Per-code coverage over ALL import_status='full' movies (heavier — scans the view).
  defp code_counts_full do
    sql = """
    SELECT mvv.metric_code, COUNT(DISTINCT mvv.movie_id)
    FROM metric_values_view mvv
    JOIN movies m ON m.id = mvv.movie_id AND m.import_status = 'full'
    WHERE mvv.normalized_value IS NOT NULL
    GROUP BY mvv.metric_code
    """

    %{rows: rows} = Cinegraph.Repo.query!(sql, [], timeout: :timer.seconds(240))
    Map.new(rows, fn [code, count] -> {code, count} end)
  end

  # %{code => MapSet of ids that HAVE a non-null value for that code} over a given id set.
  defp member_code_sets([], _codes), do: %{}

  defp member_code_sets(ids, codes) do
    %{rows: rows} =
      Cinegraph.Repo.query!(
        """
        SELECT metric_code, movie_id
        FROM metric_values_view
        WHERE movie_id = ANY($1) AND metric_code = ANY($2) AND normalized_value IS NOT NULL
        """,
        [ids, codes],
        timeout: :timer.seconds(120)
      )

    Enum.reduce(rows, %{}, fn [code, id], acc ->
      Map.update(acc, code, MapSet.new([id]), &MapSet.put(&1, id))
    end)
  end

  # Movie ids (within `ids`) that have been OMDb-fetched at all — any `source = 'omdb'` row,
  # including a `fetch_attempt`. A fetched member still missing an OMDb field has a genuinely
  # source-absent value; an unfetched one is merely not-yet-fetched.
  defp omdb_fetched_set(ids) do
    %{rows: rows} =
      Cinegraph.Repo.query!(
        """
        SELECT DISTINCT movie_id FROM external_metrics
        WHERE source = 'omdb' AND movie_id = ANY($1)
        """,
        [ids],
        timeout: :timer.seconds(60)
      )

    MapSet.new(rows, fn [id] -> id end)
  end

  defp fetch_decade_coverage(decade) do
    {:ok, start_date} = Date.new(decade, 1, 1)
    {:ok, end_date} = Date.new(decade + 9, 12, 31)

    sql = """
    SELECT
      COUNT(DISTINCT m.id)                                                               AS total,
      COUNT(DISTINCT CASE WHEN ei.id IS NOT NULL THEN m.id END)                         AS has_imdb,
      COUNT(DISTINCT CASE WHEN er.id IS NOT NULL THEN m.id END)                         AS has_rt,
      COUNT(DISTINCT CASE WHEN em2.id IS NOT NULL THEN m.id END)                        AS has_metacritic,
      COUNT(DISTINCT CASE WHEN fn.id IS NOT NULL THEN m.id END)                         AS has_festivals,
      ROUND(AVG(COALESCE(fc.nom_count, 0)), 2)                                          AS avg_nominations
    FROM movies m
    LEFT JOIN external_metrics ei   ON ei.movie_id  = m.id AND ei.source  = 'imdb'            AND ei.metric_type = 'rating_average'
    LEFT JOIN external_metrics er   ON er.movie_id  = m.id AND er.source  = 'rotten_tomatoes'  AND er.metric_type = 'tomatometer'
    LEFT JOIN external_metrics em2  ON em2.movie_id = m.id AND em2.source = 'metacritic'       AND em2.metric_type = 'metascore'
    LEFT JOIN festival_nominations fn ON fn.movie_id = m.id
    LEFT JOIN (
      SELECT movie_id, COUNT(*) AS nom_count
      FROM festival_nominations
      GROUP BY movie_id
    ) fc ON fc.movie_id = m.id
    WHERE m.import_status = 'full'
      AND m.release_date >= $1
      AND m.release_date <= $2
    """

    %{rows: [[total, has_imdb, has_rt, has_meta, has_festivals, avg_noms]]} =
      Cinegraph.Repo.query!(sql, [start_date, end_date])

    total = total || 0

    avg_noms =
      case avg_noms do
        %Decimal{} = d -> Decimal.to_float(d)
        n when is_number(n) -> Float.round(n * 1.0, 2)
        nil -> 0.0
      end

    has_imdb_pct = pct(has_imdb, total)
    has_rt_pct = pct(has_rt, total)
    has_meta_pct = pct(has_meta, total)
    has_festivals_pct = pct(has_festivals, total)

    low_coverage =
      Enum.any?([has_imdb_pct, has_rt_pct, has_meta_pct, has_festivals_pct], &(&1 < 50.0))

    %{
      decade: decade,
      label: "#{decade}s",
      total: total,
      has_imdb_pct: has_imdb_pct,
      has_rt_pct: has_rt_pct,
      has_metacritic_pct: has_meta_pct,
      has_festivals_pct: has_festivals_pct,
      avg_nominations: avg_noms,
      low_coverage: low_coverage
    }
  end

  defp print_coverage(results) do
    Mix.shell().info("""

    COVERAGE AUDIT — All Candidate Movies by Decade
    #{String.duplicate("-", 72)}
    Decade  Candidates  IMDb   RT     Meta   Festivals  Avg Noms
    #{String.duplicate("-", 72)}
    """)

    Enum.each(results, fn r ->
      flag = if r.low_coverage, do: " ⚠", else: ""

      line =
        "#{String.pad_trailing(r.label, 8)}" <>
          "#{String.pad_leading(to_string(r.total), 10)}  " <>
          "#{String.pad_leading("#{r.has_imdb_pct}%", 5)}  " <>
          "#{String.pad_leading("#{r.has_rt_pct}%", 5)}  " <>
          "#{String.pad_leading("#{r.has_metacritic_pct}%", 5)}  " <>
          "#{String.pad_leading("#{r.has_festivals_pct}%", 9)}#{flag}" <>
          "  #{r.avg_nominations}"

      Mix.shell().info(line)
    end)

    Mix.shell().info("\n(⚠ = below 50% for any source)\n")
  end

  defp pct(count, total) when is_integer(total) and total > 0,
    do: Float.round(count / total * 100, 1)

  defp pct(_, _), do: 0.0

  defp format_timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
