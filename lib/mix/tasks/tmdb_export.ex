defmodule Mix.Tasks.Tmdb.Export do
  @moduledoc """
  Mix tasks for working with TMDb daily export files.

  ## Commands

      # Download today's TMDb export file
      mix tmdb.export download

      # Download a specific date's export
      mix tmdb.export download --date 2026-01-05

      # Analyze export file contents
      mix tmdb.export analyze

      # Run gap analysis (compare export vs our database)
      mix tmdb.export gap

      # Show sample missing movies
      mix tmdb.export missing --limit 50

      # Show missing by popularity tier
      mix tmdb.export missing --by-tier
  """

  use Mix.Task

  @shortdoc "TMDb daily export operations"

  def run(args) do
    {opts, remaining, _} = OptionParser.parse(args,
      switches: [
        date: :string,
        limit: :integer,
        min_popularity: :float,
        by_tier: :boolean,
        verbose: :boolean
      ],
      aliases: [d: :date, l: :limit, v: :verbose]
    )

    command = List.first(remaining) || "help"

    Mix.Task.run("app.start")

    case command do
      "download" -> download(opts)
      "analyze" -> analyze(opts)
      "gap" -> gap_analysis(opts)
      "missing" -> show_missing(opts)
      "help" -> show_help()
      _ ->
        Mix.shell().error("Unknown command: #{command}")
        show_help()
    end
  end

  defp download(opts) do
    alias Cinegraph.Services.TMDb.DailyExport

    date = if opts[:date] do
      case Date.from_iso8601(opts[:date]) do
        {:ok, d} -> d
        {:error, _} ->
          Mix.shell().error("Invalid date format. Use YYYY-MM-DD")
          System.halt(1)
      end
    else
      Date.utc_today()
    end

    Mix.shell().info("Downloading TMDb export for #{date}...")
    Mix.shell().info("URL: #{DailyExport.export_url(date)}")

    case DailyExport.download(date: date) do
      {:ok, path} ->
        Mix.shell().info("✅ Downloaded to: #{path}")

        # Show quick stats
        Mix.shell().info("\nQuick stats:")
        counts = DailyExport.count_entries(path)
        Mix.shell().info("  Total entries: #{format_number(counts.total)}")
        Mix.shell().info("  Non-video movies: #{format_number(counts.non_video)}")
        Mix.shell().info("  Video extras: #{format_number(counts.video)}")

      {:error, :not_found} ->
        Mix.shell().error("❌ Export file not found for #{date}")
        Mix.shell().error("   Files are available ~8:00 AM UTC daily")

      {:error, reason} ->
        Mix.shell().error("❌ Download failed: #{inspect(reason)}")
    end
  end

  defp analyze(opts) do
    alias Cinegraph.Services.TMDb.DailyExport

    # Find export file
    path = find_export_file(opts)

    Mix.shell().info("Analyzing export file: #{path}")
    Mix.shell().info("")

    # Get counts
    counts = DailyExport.count_entries(path)

    Mix.shell().info("📊 EXPORT FILE ANALYSIS")
    Mix.shell().info(String.duplicate("=", 50))
    Mix.shell().info("")
    Mix.shell().info("Total entries:       #{format_number(counts.total)}")
    Mix.shell().info("Non-video movies:    #{format_number(counts.non_video)}")
    Mix.shell().info("Video extras:        #{format_number(counts.video)}")
    Mix.shell().info("Adult content:       #{format_number(counts.adult)}")
    Mix.shell().info("")
    Mix.shell().info("📈 POPULARITY DISTRIBUTION (non-video)")
    Mix.shell().info("  pop >= 100:    #{format_number(counts.pop_100_plus)} (blockbusters)")
    Mix.shell().info("  pop 50-100:    #{format_number(counts.pop_50_100)} (major releases)")
    Mix.shell().info("  pop 10-50:     #{format_number(counts.pop_10_50)} (notable)")
    Mix.shell().info("  pop 1-10:      #{format_number(counts.pop_1_10)} (standard)")
    Mix.shell().info("  pop < 1:       #{format_number(counts.pop_below_1)} (obscure)")
    Mix.shell().info("")

    # Show samples
    if opts[:verbose] do
      samples = DailyExport.sample_by_popularity(path, 5)

      Mix.shell().info("🎬 SAMPLE MOVIES")
      Mix.shell().info("")
      Mix.shell().info("High popularity (≥10):")
      Enum.each(samples.high, fn m ->
        Mix.shell().info("  #{Float.round(m.popularity, 1)} - #{m.original_title}")
      end)

      Mix.shell().info("")
      Mix.shell().info("Medium popularity (1-10):")
      Enum.each(samples.medium, fn m ->
        Mix.shell().info("  #{Float.round(m.popularity, 1)} - #{m.original_title}")
      end)
    end
  end

  defp gap_analysis(_opts) do
    alias Cinegraph.Services.TMDb.GapAnalysis

    Mix.shell().info("Running gap analysis...")
    Mix.shell().info("This downloads the TMDb export and compares against our database.")
    Mix.shell().info("")

    case GapAnalysis.analyze() do
      {:ok, report} ->
        GapAnalysis.print_report(report)

      {:error, reason} ->
        Mix.shell().error("❌ Gap analysis failed: #{inspect(reason)}")
    end
  end

  defp show_missing(opts) do
    alias Cinegraph.Services.TMDb.GapAnalysis

    if opts[:by_tier] do
      show_missing_by_tier(opts)
    else
      show_missing_list(opts)
    end
  end

  defp show_missing_list(opts) do
    alias Cinegraph.Services.TMDb.GapAnalysis

    limit = opts[:limit] || 20
    min_pop = opts[:min_popularity]

    Mix.shell().info("Finding missing movies...")

    find_opts = [limit: limit]
    find_opts = if min_pop, do: [{:min_popularity, min_pop} | find_opts], else: find_opts

    case GapAnalysis.find_missing_ids(find_opts) do
      {:ok, missing} ->
        Mix.shell().info("")
        Mix.shell().info("📽️  MISSING MOVIES (top #{length(missing)} by popularity)")
        Mix.shell().info(String.duplicate("=", 60))

        Enum.with_index(missing, 1)
        |> Enum.each(fn {m, idx} ->
          pop = Float.round(m.popularity, 2)
          Mix.shell().info("#{String.pad_leading("#{idx}", 3)}. [#{pop}] #{m.original_title} (ID: #{m.id})")
        end)

        Mix.shell().info("")
        Mix.shell().info("Use --limit N to see more, or --min-popularity N to filter")

      {:error, reason} ->
        Mix.shell().error("❌ Failed: #{inspect(reason)}")
    end
  end

  defp show_missing_by_tier(_opts) do
    alias Cinegraph.Services.TMDb.GapAnalysis

    Mix.shell().info("Finding missing movies by tier...")

    case GapAnalysis.find_missing_by_tier() do
      {:ok, grouped} ->
        Mix.shell().info("")
        Mix.shell().info("📊 MISSING MOVIES BY TIER")
        Mix.shell().info(String.duplicate("=", 60))

        tiers = [
          {:tier_1_blockbuster, "🔥 Tier 1: Blockbusters (pop 100+)"},
          {:tier_2_popular, "⭐ Tier 2: Popular (pop 10-100)"},
          {:tier_3_notable, "📽️  Tier 3: Notable (pop 1-10)"},
          {:tier_4_obscure, "🎬 Tier 4: Obscure (pop 0.1-1)"},
          {:tier_5_very_obscure, "📼 Tier 5: Very Obscure (pop <0.1)"}
        ]

        Enum.each(tiers, fn {key, label} ->
          movies = grouped[key] || []
          Mix.shell().info("")
          Mix.shell().info("#{label}")
          Mix.shell().info("  Missing: #{format_number(length(movies))}")

          # Show top 5 from each tier
          movies
          |> Enum.take(5)
          |> Enum.each(fn m ->
            Mix.shell().info("    • #{m.original_title} (#{Float.round(m.popularity, 2)})")
          end)

          if length(movies) > 5 do
            Mix.shell().info("    ... and #{length(movies) - 5} more")
          end
        end)

        # Summary
        total_missing = grouped |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
        priority = (grouped[:tier_1_blockbuster] || []) ++
                   (grouped[:tier_2_popular] || []) ++
                   (grouped[:tier_3_notable] || [])

        Mix.shell().info("")
        Mix.shell().info("📋 SUMMARY")
        Mix.shell().info("  Total missing: #{format_number(total_missing)}")
        Mix.shell().info("  Priority (tiers 1-3): #{format_number(length(priority))}")
        Mix.shell().info("  Est. time @ 10K/day: #{ceil(length(priority) / 10_000)} days")

      {:error, reason} ->
        Mix.shell().error("❌ Failed: #{inspect(reason)}")
    end
  end

  defp show_help do
    Mix.shell().info("""

    TMDb Export Commands
    ====================

    mix tmdb.export download          Download today's export file
    mix tmdb.export download -d DATE  Download specific date (YYYY-MM-DD)
    mix tmdb.export analyze           Analyze export file contents
    mix tmdb.export analyze -v        Analyze with sample movies
    mix tmdb.export gap               Run full gap analysis vs database
    mix tmdb.export missing           Show missing movies
    mix tmdb.export missing -l 50     Show top 50 missing by popularity
    mix tmdb.export missing --by-tier Show missing grouped by tier

    Options:
      -d, --date DATE           Specific date (YYYY-MM-DD)
      -l, --limit N             Limit results
      --min-popularity N        Filter by minimum popularity
      --by-tier                 Group missing by popularity tier
      -v, --verbose             Show more details

    """)
  end

  defp find_export_file(opts) do
    date = if opts[:date] do
      case Date.from_iso8601(opts[:date]) do
        {:ok, d} -> d
        {:error, _} -> Date.utc_today()
      end
    else
      Date.utc_today()
    end

    # Check common locations
    formatted = format_date(date)
    possible_paths = [
      "/tmp/movie_ids_#{formatted}.json",
      Path.join(System.tmp_dir!(), "movie_ids_#{formatted}.json"),
      "movie_ids_#{formatted}.json"
    ]

    case Enum.find(possible_paths, &File.exists?/1) do
      nil ->
        Mix.shell().info("Export file not found locally. Downloading...")
        case Cinegraph.Services.TMDb.DailyExport.download(date: date) do
          {:ok, path} -> path
          {:error, _} ->
            Mix.shell().error("Failed to download export file")
            System.halt(1)
        end

      path ->
        path
    end
  end

  defp format_date(date) do
    month = date.month |> Integer.to_string() |> String.pad_leading(2, "0")
    day = date.day |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{month}_#{day}_#{date.year}"
  end

  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n), do: "#{n}"
end
