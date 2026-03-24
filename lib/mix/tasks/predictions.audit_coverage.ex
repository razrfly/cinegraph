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

  @shortdoc "Data completeness audit by decade for candidate movies"

  @decades 1920..2020//10

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          decade: :integer,
          json: :boolean
        ]
      )

    decade_filter = Keyword.get(opts, :decade)
    json? = Keyword.get(opts, :json, false)

    decades =
      if decade_filter do
        [decade_filter]
      else
        Enum.to_list(@decades)
      end

    unless json? do
      Mix.shell().info("Auditing data coverage by decade...")
    end

    results = Enum.map(decades, &fetch_decade_coverage/1)

    if json? do
      output = %{
        "task" => "predictions.audit_coverage",
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

  defp fetch_decade_coverage(decade) do
    start_date = "#{decade}-01-01"
    end_date = "#{decade + 9}-12-31"

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
