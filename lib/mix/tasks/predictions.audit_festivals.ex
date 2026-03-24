defmodule Mix.Tasks.Predictions.AuditFestivals do
  @moduledoc """
  Lists confirmed 1001 Movies with zero festival nominations in the DB, grouped by decade.

  This helps identify where festival coverage gaps are degrading prediction accuracy.

  ## Usage

      mix predictions.audit_festivals
      mix predictions.audit_festivals --decade 1960
      mix predictions.audit_festivals --json

  ## Options

    * `--decade` - audit a single decade (e.g. 1960 for 1960s)
    * `--json` - output raw JSON instead of formatted table

  """
  use Mix.Task

  @shortdoc "1001 Movies with zero festival nominations, grouped by decade"

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

    unless json? do
      Mix.shell().info("Auditing 1001 Movies missing festival data...")
    end

    missing_movies = fetch_missing_festival_movies(decade_filter)
    total_1001 = fetch_total_1001_count(decade_filter)

    # Group by decade in Elixir
    by_decade =
      missing_movies
      |> Enum.group_by(fn {_id, _title, year} -> div(year, 10) * 10 end)
      |> Enum.sort_by(fn {decade, _} -> decade end)
      |> Enum.map(fn {decade, movies} ->
        titles = movies |> Enum.map(fn {_id, title, _year} -> title end) |> Enum.take(5)
        decade_total = Map.get(total_1001, decade, 0)

        %{
          decade: decade,
          label: "#{decade}s",
          total_1001: decade_total,
          missing_count: length(movies),
          missing_pct: pct(length(movies), decade_total),
          examples: titles
        }
      end)

    total_missing = length(missing_movies)
    grand_total = Enum.sum(Map.values(total_1001))

    if json? do
      output = %{
        "task" => "predictions.audit_festivals",
        "timestamp" => format_timestamp(),
        "total_missing" => total_missing,
        "total_1001" => grand_total,
        "missing_pct" => pct(total_missing, grand_total),
        "decades" =>
          Enum.map(by_decade, fn r ->
            %{
              "decade" => r.decade,
              "label" => r.label,
              "total_1001" => r.total_1001,
              "missing_festival_data" => r.missing_count,
              "missing_pct" => r.missing_pct,
              "examples" => r.examples
            }
          end)
      }

      IO.puts(Jason.encode!(output, pretty: true))
    else
      print_festival_audit(by_decade, total_missing, grand_total)
    end
  end

  defp fetch_missing_festival_movies(nil) do
    sql = """
    SELECT m.id, m.title, EXTRACT(YEAR FROM m.release_date)::int AS year
    FROM movies m
    WHERE (m.canonical_sources ? '1001_movies')
      AND NOT EXISTS (
        SELECT 1 FROM festival_nominations fn WHERE fn.movie_id = m.id
      )
      AND m.release_date IS NOT NULL
    ORDER BY m.release_date
    """

    %{rows: rows} = Cinegraph.Repo.query!(sql, [])
    Enum.map(rows, fn [id, title, year] -> {id, title, year} end)
  end

  defp fetch_missing_festival_movies(decade) do
    start_date = "#{decade}-01-01"
    end_date = "#{decade + 9}-12-31"

    sql = """
    SELECT m.id, m.title, EXTRACT(YEAR FROM m.release_date)::int AS year
    FROM movies m
    WHERE (m.canonical_sources ? '1001_movies')
      AND NOT EXISTS (
        SELECT 1 FROM festival_nominations fn WHERE fn.movie_id = m.id
      )
      AND m.release_date IS NOT NULL
      AND m.release_date >= $1
      AND m.release_date <= $2
    ORDER BY m.release_date
    """

    %{rows: rows} = Cinegraph.Repo.query!(sql, [start_date, end_date])
    Enum.map(rows, fn [id, title, year] -> {id, title, year} end)
  end

  defp fetch_total_1001_count(nil) do
    sql = """
    SELECT
      (FLOOR(EXTRACT(YEAR FROM m.release_date) / 10) * 10)::int AS decade,
      COUNT(*) AS cnt
    FROM movies m
    WHERE (m.canonical_sources ? '1001_movies')
      AND m.release_date IS NOT NULL
    GROUP BY decade
    ORDER BY decade
    """

    %{rows: rows} = Cinegraph.Repo.query!(sql, [])
    Map.new(rows, fn [decade, cnt] -> {decade, cnt} end)
  end

  defp fetch_total_1001_count(decade) do
    start_date = "#{decade}-01-01"
    end_date = "#{decade + 9}-12-31"

    sql = """
    SELECT COUNT(*) FROM movies m
    WHERE (m.canonical_sources ? '1001_movies')
      AND m.release_date IS NOT NULL
      AND m.release_date >= $1
      AND m.release_date <= $2
    """

    %{rows: [[cnt]]} = Cinegraph.Repo.query!(sql, [start_date, end_date])
    %{decade => cnt}
  end

  defp print_festival_audit(by_decade, total_missing, grand_total) do
    missing_pct = pct(total_missing, grand_total)

    Mix.shell().info("""

    FESTIVAL AUDIT — 1001 Movies with Zero Festival Nominations
    Total missing: #{total_missing}/#{grand_total} (#{missing_pct}%)
    #{String.duplicate("-", 60)}
    """)

    Enum.each(by_decade, fn r ->
      examples = Enum.join(r.examples, ", ")
      flag = if r.missing_pct > 20.0, do: " ⚠", else: ""

      Mix.shell().info(
        "  #{String.pad_trailing(r.label, 6)}  #{r.missing_count}/#{r.total_1001} (#{r.missing_pct}%)#{flag}   e.g. #{examples}"
      )
    end)

    Mix.shell().info("")
  end

  defp pct(count, total) when is_integer(total) and total > 0,
    do: Float.round(count / total * 100, 1)

  defp pct(_, _), do: 0.0

  defp format_timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
