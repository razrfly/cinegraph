defmodule Cinegraph.Services.TMDb.PeopleGapAnalysis do
  @moduledoc """
  Analyzes gaps between TMDb's complete person catalog and our database.

  Uses TMDb daily person export files to identify:
  - People we're missing entirely
  - Coverage percentage by popularity tier
  - People we have that TMDb doesn't (deleted/merged accounts)

  ## Usage

      # Full gap analysis
      {:ok, report} = PeopleGapAnalysis.analyze()

      # Quick summary
      {:ok, summary} = PeopleGapAnalysis.quick_summary()

      # Print formatted report
      PeopleGapAnalysis.print_report(report)
  """

  import Ecto.Query
  alias Cinegraph.{Repo, Movies.Person}
  alias Cinegraph.Services.TMDb.DailyExport
  require Logger

  @type analysis_report :: %{
          date: Date.t(),
          export_path: String.t(),
          export_total: integer(),
          export_non_adult: integer(),
          our_total: integer(),
          missing_count: integer(),
          extra_in_our_db: integer(),
          coverage_percent: float(),
          by_popularity: map(),
          recommendations: list()
        }

  @doc """
  Performs a complete gap analysis for people.

  Downloads the latest TMDb person export, compares against our database,
  and returns a detailed report.

  ## Options
    - `:export_path` - Path to already-downloaded export file
    - `:min_popularity` - Only analyze people above this threshold
    - `:skip_download` - Use existing file at default location
  """
  @spec analyze(keyword()) :: {:ok, analysis_report()} | {:error, term()}
  def analyze(opts \\ []) do
    Logger.info("Starting TMDb people gap analysis...")

    with {:ok, export_path} <- ensure_export(opts),
         {:ok, export_ids} <- load_export_ids(export_path, opts),
         {:ok, our_ids} <- load_our_ids(),
         {:ok, export_entries} <- load_export_entries(export_path, opts) do
      missing_ids = MapSet.difference(export_ids, our_ids)
      extra_ids = MapSet.difference(our_ids, export_ids)

      # Categorize missing by popularity
      missing_by_popularity = categorize_missing_by_popularity(export_entries, missing_ids)

      # Build report
      report = %{
        date: Date.utc_today(),
        export_path: export_path,
        export_total: MapSet.size(export_ids),
        our_total: MapSet.size(our_ids),
        missing_count: MapSet.size(missing_ids),
        extra_in_our_db: MapSet.size(extra_ids),
        coverage_percent: calculate_coverage(our_ids, export_ids),
        by_popularity: missing_by_popularity,
        recommendations: build_recommendations(missing_by_popularity)
      }

      Logger.info("People gap analysis complete. Missing #{report.missing_count} people.")
      {:ok, report}
    end
  end

  @doc """
  Gets export statistics efficiently for progress tracking.

  Returns:
    - export_total: Total non-adult people in TMDb
    - our_total: People in our database with tmdb_id
    - missing_count: People we don't have
    - coverage_percent: Our coverage percentage
    - export_date: Date of the export file used
  """
  @spec get_export_stats(keyword()) :: {:ok, map()} | {:error, term()}
  def get_export_stats(opts \\ []) do
    with {:ok, export_path} <- ensure_export(Keyword.put_new(opts, :skip_download, true)),
         {:ok, export_ids} <- load_export_ids(export_path, opts),
         {:ok, our_ids} <- load_our_ids() do
      export_total = MapSet.size(export_ids)
      our_total = MapSet.size(our_ids)
      overlap = MapSet.intersection(our_ids, export_ids) |> MapSet.size()
      missing_count = export_total - overlap

      coverage_percent =
        if export_total > 0 do
          Float.round(overlap / export_total * 100, 2)
        else
          0.0
        end

      # Extract date from export path
      export_date = extract_date_from_path(export_path)

      {:ok,
       %{
         export_total: export_total,
         our_total: our_total,
         overlap: overlap,
         missing_count: missing_count,
         coverage_percent: coverage_percent,
         export_date: export_date,
         export_path: export_path
       }}
    else
      {:error, :file_not_found} ->
        # No cached file, try downloading
        get_export_stats(Keyword.put(opts, :skip_download, false))

      error ->
        error
    end
  end

  @doc """
  Quick summary - returns counts and basic stats.
  """
  @spec quick_summary() :: {:ok, map()} | {:error, term()}
  def quick_summary do
    our_count = Repo.one(from p in Person, where: not is_nil(p.tmdb_id), select: count(p.id))
    our_without_tmdb = Repo.one(from p in Person, where: is_nil(p.tmdb_id), select: count(p.id))

    {:ok,
     %{
       our_people_with_tmdb_id: our_count,
       our_people_without_tmdb_id: our_without_tmdb,
       total_in_db: our_count + our_without_tmdb,
       note: "Run full analyze/0 for detailed gap analysis against TMDb export"
     }}
  end

  @doc """
  Prints a formatted gap analysis report to the console.
  """
  @spec print_report(analysis_report()) :: :ok
  def print_report(report) do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("TMDb PEOPLE GAP ANALYSIS REPORT")
    IO.puts("Date: #{report.date}")
    IO.puts(String.duplicate("=", 60))

    IO.puts("\n📊 OVERVIEW")
    IO.puts("  TMDb Export Total:     #{format_number(report.export_total)}")
    IO.puts("  Our Database:          #{format_number(report.our_total)}")
    IO.puts("  Missing:               #{format_number(report.missing_count)}")
    IO.puts("  Coverage:              #{Float.round(report.coverage_percent, 2)}%")

    if report.extra_in_our_db > 0 do
      IO.puts("  Extra (deleted/merged?): #{format_number(report.extra_in_our_db)}")
    end

    IO.puts("\n📈 MISSING BY POPULARITY TIER")

    report.by_popularity
    |> Enum.sort_by(fn {tier, _} -> tier_order(tier) end)
    |> Enum.each(fn {tier, data} ->
      IO.puts("  #{tier_label(tier)}")

      IO.puts(
        "    Missing: #{format_number(data.missing)} / #{format_number(data.total)} (#{Float.round(data.coverage, 1)}% coverage)"
      )
    end)

    IO.puts("\n💡 RECOMMENDATIONS")

    Enum.each(report.recommendations, fn rec ->
      IO.puts("  • #{rec}")
    end)

    IO.puts("\n" <> String.duplicate("=", 60))
    :ok
  end

  # Private functions

  defp ensure_export(opts) do
    cond do
      opts[:export_path] ->
        if File.exists?(opts[:export_path]) do
          {:ok, opts[:export_path]}
        else
          {:error, :file_not_found}
        end

      opts[:skip_download] ->
        default_path =
          Path.join(System.tmp_dir!(), "person_ids_#{format_date(Date.utc_today())}.json")

        if File.exists?(default_path) do
          {:ok, default_path}
        else
          {:error, :file_not_found}
        end

      true ->
        DailyExport.download_people()
    end
  end

  defp load_export_ids(path, opts) do
    Logger.info("Loading person export IDs from #{path}...")

    DailyExport.get_all_person_ids(path,
      skip_adult: true,
      min_popularity: opts[:min_popularity]
    )
  end

  defp load_export_entries(path, opts) do
    Logger.info("Loading person export entries for analysis...")

    entries =
      DailyExport.stream_people(path,
        skip_adult: true,
        min_popularity: opts[:min_popularity]
      )
      |> Enum.reduce(%{}, fn entry, acc ->
        Map.put(acc, entry.id, entry)
      end)

    {:ok, entries}
  end

  defp load_our_ids do
    Logger.info("Loading our person IDs from database...")

    ids =
      Repo.all(from p in Person, where: not is_nil(p.tmdb_id), select: p.tmdb_id)
      |> MapSet.new()

    Logger.info("Found #{MapSet.size(ids)} people with TMDb IDs in our database")
    {:ok, ids}
  end

  defp categorize_missing_by_popularity(export_entries, missing_ids) do
    tiers = %{
      "100+" => %{min: 100, max: :infinity},
      "50-100" => %{min: 50, max: 100},
      "10-50" => %{min: 10, max: 50},
      "1-10" => %{min: 1, max: 10},
      "<1" => %{min: 0, max: 1}
    }

    Enum.map(tiers, fn {tier_name, %{min: min, max: max}} ->
      tier_entries =
        Enum.filter(export_entries, fn {_id, entry} ->
          entry.popularity >= min && (max == :infinity || entry.popularity < max)
        end)

      tier_ids = Enum.map(tier_entries, fn {id, _} -> id end) |> MapSet.new()
      missing_in_tier = MapSet.intersection(tier_ids, missing_ids) |> MapSet.size()
      total_in_tier = MapSet.size(tier_ids)

      coverage =
        if total_in_tier > 0 do
          (total_in_tier - missing_in_tier) / total_in_tier * 100
        else
          100.0
        end

      {tier_name,
       %{
         total: total_in_tier,
         missing: missing_in_tier,
         have: total_in_tier - missing_in_tier,
         coverage: coverage
       }}
    end)
    |> Enum.into(%{})
  end

  defp calculate_coverage(our_ids, export_ids) do
    overlap = MapSet.intersection(our_ids, export_ids) |> MapSet.size()
    export_size = MapSet.size(export_ids)

    if export_size > 0 do
      overlap / export_size * 100
    else
      0.0
    end
  end

  defp build_recommendations(by_popularity) do
    recommendations = []

    # Check high-priority tiers (popular actors/directors)
    high_pop = by_popularity["100+"] || %{missing: 0}
    med_pop = by_popularity["50-100"] || %{missing: 0}
    notable = by_popularity["10-50"] || %{missing: 0}

    recommendations =
      if high_pop.missing > 0 do
        ["PRIORITY: Missing #{high_pop.missing} famous people (popularity 100+)" | recommendations]
      else
        ["✅ Have all famous people (popularity 100+)" | recommendations]
      end

    recommendations =
      if med_pop.missing > 0 do
        ["Missing #{med_pop.missing} well-known people (popularity 50-100)" | recommendations]
      else
        recommendations
      end

    recommendations =
      if notable.missing > 0 do
        ["Missing #{notable.missing} notable people (popularity 10-50)" | recommendations]
      else
        recommendations
      end

    # Note about how people are typically imported
    recommendations = [
      "Note: People are imported with movies (via credits), not separately" | recommendations
    ]

    Enum.reverse(recommendations)
  end

  defp extract_date_from_path(path) do
    case Regex.run(~r/person_ids_(\d{2})_(\d{2})_(\d{4})\.json/, path) do
      [_, month, day, year] ->
        case Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day)) do
          {:ok, date} -> date
          _ -> Date.utc_today()
        end

      _ ->
        Date.utc_today()
    end
  end

  defp format_date(date) do
    month = date.month |> Integer.to_string() |> String.pad_leading(2, "0")
    day = date.day |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{month}_#{day}_#{date.year}"
  end

  defp format_number(n) when n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end

  defp format_number(n) when n >= 1_000 do
    "#{Float.round(n / 1_000, 1)}K"
  end

  defp format_number(n), do: "#{n}"

  defp tier_order("100+"), do: 0
  defp tier_order("50-100"), do: 1
  defp tier_order("10-50"), do: 2
  defp tier_order("1-10"), do: 3
  defp tier_order("<1"), do: 4
  defp tier_order(_), do: 99

  defp tier_label("100+"), do: "🌟 Famous (popularity 100+)"
  defp tier_label("50-100"), do: "⭐ Well-Known (popularity 50-100)"
  defp tier_label("10-50"), do: "🎭 Notable (popularity 10-50)"
  defp tier_label("1-10"), do: "🎬 Working (popularity 1-10)"
  defp tier_label("<1"), do: "📼 Obscure (popularity <1)"
  defp tier_label(other), do: other
end
