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

      # Backfill missing movies (queue for import)
      mix tmdb.export backfill --dry-run           # Preview what would be imported
      mix tmdb.export backfill --limit 100         # Import 100 movies
      mix tmdb.export backfill --min-popularity 10 # Only high-priority movies
      mix tmdb.export backfill                     # Import all missing movies

      # Continuous backfill (automated, runs until complete)
      mix tmdb.export continuous --start           # Start continuous backfill
      mix tmdb.export continuous --status          # Check status
      mix tmdb.export continuous --stop            # Pause backfill
      mix tmdb.export continuous --resume          # Resume paused backfill
  """

  use Mix.Task

  @shortdoc "TMDb daily export operations"

  def run(args) do
    {opts, remaining, _} =
      OptionParser.parse(args,
        switches: [
          date: :string,
          limit: :integer,
          min_popularity: :float,
          by_tier: :boolean,
          verbose: :boolean,
          # Backfill options
          dry_run: :boolean,
          batch_size: :integer,
          offset: :integer,
          # Continuous backfill options
          start: :boolean,
          stop: :boolean,
          status: :boolean,
          resume: :boolean
        ],
        aliases: [d: :date, l: :limit, v: :verbose, n: :dry_run]
      )

    command = List.first(remaining) || "help"

    Mix.Task.run("app.start")

    case command do
      "download" ->
        download(opts)

      "analyze" ->
        analyze(opts)

      "gap" ->
        gap_analysis(opts)

      "missing" ->
        show_missing(opts)

      "backfill" ->
        run_backfill(opts)

      "year-status" ->
        show_year_status(opts)

      "continuous" ->
        run_continuous(opts)

      "help" ->
        show_help()

      _ ->
        Mix.shell().error("Unknown command: #{command}")
        show_help()
    end
  end

  defp download(opts) do
    alias Cinegraph.Services.TMDb.DailyExport

    date =
      if opts[:date] do
        case Date.from_iso8601(opts[:date]) do
          {:ok, d} ->
            d

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

          Mix.shell().info(
            "#{String.pad_leading("#{idx}", 3)}. [#{pop}] #{m.original_title} (ID: #{m.id})"
          )
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

        priority =
          (grouped[:tier_1_blockbuster] || []) ++
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

  defp run_backfill(opts) do
    alias Cinegraph.Workers.ExportBackfillWorker

    limit = opts[:limit]
    min_popularity = opts[:min_popularity]
    batch_size = opts[:batch_size] || 100
    dry_run = opts[:dry_run] || false
    offset = opts[:offset] || 0

    Mix.shell().info("")
    Mix.shell().info("🚀 TMDb EXPORT BACKFILL")
    Mix.shell().info(String.duplicate("=", 60))
    Mix.shell().info("")
    Mix.shell().info("Configuration:")
    Mix.shell().info("  Limit:          #{inspect(limit) || "all"}")
    Mix.shell().info("  Min popularity: #{inspect(min_popularity) || "none"}")
    Mix.shell().info("  Batch size:     #{batch_size}")
    Mix.shell().info("  Offset:         #{offset}")
    Mix.shell().info("  Dry run:        #{dry_run}")
    Mix.shell().info("")

    if dry_run do
      Mix.shell().info("🔍 DRY RUN MODE - No jobs will be queued")
      Mix.shell().info("")
    end

    case ExportBackfillWorker.run_backfill(limit, min_popularity, batch_size, dry_run, offset) do
      {:ok, stats} ->
        Mix.shell().info("")
        Mix.shell().info("✅ BACKFILL COMPLETE")
        Mix.shell().info(String.duplicate("=", 60))

        if dry_run do
          Mix.shell().info("")
          Mix.shell().info("Would queue: #{format_number(stats.total)} movies")
          Mix.shell().info("")
          Mix.shell().info("By popularity tier:")

          Enum.each(stats.by_tier, fn {tier, count} ->
            Mix.shell().info("  #{tier}: #{format_number(count)}")
          end)

          Mix.shell().info("")
          Mix.shell().info("To actually import, run without --dry-run:")
          Mix.shell().info("  mix tmdb.export backfill --limit #{stats.total}")
        else
          Mix.shell().info("")
          Mix.shell().info("Queued: #{format_number(stats.queued)} jobs")
          Mix.shell().info("")
          Mix.shell().info("Jobs are now processing in the :tmdb queue.")
          Mix.shell().info("Monitor progress with: mix tmdb.export gap")
        end

      {:error, reason} ->
        Mix.shell().error("❌ Backfill failed: #{inspect(reason)}")
    end
  end

  defp run_continuous(opts) do
    alias Cinegraph.Workers.ContinuousBackfillWorker

    cond do
      opts[:start] ->
        start_continuous(opts)

      opts[:stop] ->
        stop_continuous()

      opts[:resume] ->
        resume_continuous()

      # Default to status if no other option specified
      true ->
        show_continuous_status()
    end
  end

  defp start_continuous(opts) do
    alias Cinegraph.Workers.ContinuousBackfillWorker

    batch_size = opts[:batch_size] || 10_000
    min_popularity = opts[:min_popularity] || 1.0

    Mix.shell().info("")
    Mix.shell().info("🚀 STARTING CONTINUOUS BACKFILL")
    Mix.shell().info(String.duplicate("=", 60))
    Mix.shell().info("")
    Mix.shell().info("Configuration:")
    Mix.shell().info("  Batch size:     #{format_number(batch_size)} movies per batch")
    Mix.shell().info("  Min popularity: #{min_popularity}")
    Mix.shell().info("  Poll interval:  5 minutes")
    Mix.shell().info("")

    case ContinuousBackfillWorker.start(batch_size: batch_size, min_popularity: min_popularity) do
      {:ok, _job} ->
        Mix.shell().info("✅ Continuous backfill started!")
        Mix.shell().info("")
        Mix.shell().info("The system will now:")
        Mix.shell().info("  1. Queue #{format_number(batch_size)} movies")
        Mix.shell().info("  2. Wait for batch to complete (~75 minutes per 10K)")
        Mix.shell().info("  3. Automatically queue next batch")
        Mix.shell().info("  4. Repeat until all movies are imported")
        Mix.shell().info("")
        Mix.shell().info("Monitor progress with: mix tmdb.export continuous --status")
        Mix.shell().info("Stop/pause with:       mix tmdb.export continuous --stop")

      {:error, :already_running} ->
        Mix.shell().info("⚠️  Continuous backfill is already running!")
        Mix.shell().info("   Use --status to check progress or --stop to pause")

      {:error, reason} ->
        Mix.shell().error("❌ Failed to start: #{inspect(reason)}")
    end
  end

  defp stop_continuous do
    alias Cinegraph.Workers.ContinuousBackfillWorker

    Mix.shell().info("")
    Mix.shell().info("⏸️  PAUSING CONTINUOUS BACKFILL")
    Mix.shell().info(String.duplicate("=", 60))

    ContinuousBackfillWorker.stop()

    Mix.shell().info("")
    Mix.shell().info("✅ Continuous backfill paused")
    Mix.shell().info("   Jobs currently in queue will continue processing")
    Mix.shell().info("   No new batches will be queued")
    Mix.shell().info("")
    Mix.shell().info("Resume with: mix tmdb.export continuous --resume")
  end

  defp resume_continuous do
    alias Cinegraph.Workers.ContinuousBackfillWorker

    Mix.shell().info("")
    Mix.shell().info("▶️  RESUMING CONTINUOUS BACKFILL")
    Mix.shell().info(String.duplicate("=", 60))

    case ContinuousBackfillWorker.resume() do
      {:ok, _job} ->
        Mix.shell().info("")
        Mix.shell().info("✅ Continuous backfill resumed!")
        Mix.shell().info("   Next batch will be queued shortly")

      {:error, :already_running} ->
        Mix.shell().info("⚠️  Continuous backfill is already running!")

      {:error, :already_completed} ->
        Mix.shell().info("✅ Backfill already completed - no more movies to import!")

      {:error, :not_started} ->
        Mix.shell().info(
          "⚠️  No backfill to resume. Start one with: mix tmdb.export continuous --start"
        )

      {:error, reason} ->
        Mix.shell().error("❌ Failed to resume: #{inspect(reason)}")
    end
  end

  defp show_continuous_status do
    alias Cinegraph.Workers.ContinuousBackfillWorker
    import Ecto.Query
    alias Cinegraph.{Repo, Movies.Movie}

    status = ContinuousBackfillWorker.get_detailed_status()

    Mix.shell().info("")
    Mix.shell().info("📊 CONTINUOUS BACKFILL STATUS")
    Mix.shell().info(String.duplicate("=", 60))
    Mix.shell().info("")

    # Status indicator
    status_emoji =
      case status.status do
        "running" -> "🟢"
        "paused" -> "🟡"
        "completed" -> "✅"
        _ -> "⚪"
      end

    Mix.shell().info("Status: #{status_emoji} #{String.upcase(status.status)}")
    Mix.shell().info("")

    if status.started_at do
      Mix.shell().info("Started:          #{status.started_at}")
    end

    Mix.shell().info("Current batch:    ##{status.current_batch}")
    Mix.shell().info("Batch size:       #{format_number(status.batch_size)}")
    Mix.shell().info("Total queued:     #{format_number(status.total_queued)} movies")
    Mix.shell().info("")

    # Current job stats
    Mix.shell().info("📦 JOB QUEUE (tmdb)")
    Mix.shell().info("  Pending:        #{format_number(status.pending_jobs)}")
    Mix.shell().info("  Executing:      #{format_number(status.executing_jobs)}")
    Mix.shell().info("")

    # Database stats
    movie_count = Repo.one(from m in Movie, select: count(m.id))
    Mix.shell().info("🎬 DATABASE")
    Mix.shell().info("  Total movies:   #{format_number(movie_count)}")

    if status.estimated_remaining > 0 do
      Mix.shell().info("  Est. remaining: #{format_number(status.estimated_remaining)}")
      Mix.shell().info("  Est. batches:   #{status.estimated_batches_remaining}")

      # Time estimate: ~75 min per 10K batch
      minutes_remaining = status.estimated_batches_remaining * 75
      hours = div(minutes_remaining, 60)
      mins = rem(minutes_remaining, 60)
      Mix.shell().info("  Est. time:      #{hours}h #{mins}m")
    end

    Mix.shell().info("")

    # Show helpful commands based on status
    case status.status do
      "running" ->
        Mix.shell().info("Commands:")
        Mix.shell().info("  mix tmdb.export continuous --stop   # Pause backfill")

      "paused" ->
        Mix.shell().info("Commands:")
        Mix.shell().info("  mix tmdb.export continuous --resume # Resume backfill")

      "completed" ->
        Mix.shell().info("🎉 All movies have been imported!")

      _ ->
        Mix.shell().info("Commands:")
        Mix.shell().info("  mix tmdb.export continuous --start  # Start backfill")
    end

    Mix.shell().info("")
  end

  defp show_year_status(opts) do
    import Ecto.Query
    alias Cinegraph.{Repo, Movies.Movie}

    limit = opts[:limit] || 30

    Mix.shell().info("")
    Mix.shell().info("📅 YEAR-BY-YEAR MOVIE COVERAGE")
    Mix.shell().info(String.duplicate("=", 60))
    Mix.shell().info("")

    # Query movies grouped by release year
    year_counts =
      from(m in Movie,
        where: not is_nil(m.release_date),
        select: {fragment("EXTRACT(YEAR FROM ?)::integer", m.release_date), count(m.id)},
        group_by: fragment("EXTRACT(YEAR FROM ?)", m.release_date),
        order_by: [desc: fragment("EXTRACT(YEAR FROM ?)", m.release_date)]
      )
      |> Repo.all()

    # Get total count
    total_movies = Repo.one(from m in Movie, select: count(m.id))
    movies_with_year = Enum.reduce(year_counts, 0, fn {_year, count}, acc -> acc + count end)

    # Display header
    Mix.shell().info(
      "#{String.pad_trailing("Year", 8)} │ #{String.pad_leading("Movies", 10)} │ Bar"
    )

    Mix.shell().info(String.duplicate("─", 60))

    # Find max count for scaling bars
    max_count = year_counts |> Enum.map(fn {_, c} -> c end) |> Enum.max(fn -> 1 end)

    # Display each year (limited)
    year_counts
    |> Enum.take(limit)
    |> Enum.each(fn {year, count} ->
      bar_width = round(count / max_count * 30)
      bar = String.duplicate("█", bar_width)
      year_str = if year, do: "#{trunc(year)}", else: "Unknown"

      Mix.shell().info(
        "#{String.pad_trailing(year_str, 8)} │ #{String.pad_leading(format_number(count), 10)} │ #{bar}"
      )
    end)

    if length(year_counts) > limit do
      Mix.shell().info("  ... and #{length(year_counts) - limit} more years")
    end

    Mix.shell().info("")
    Mix.shell().info(String.duplicate("─", 60))
    Mix.shell().info("📊 SUMMARY")
    Mix.shell().info("  Total movies in database: #{format_number(total_movies)}")
    Mix.shell().info("  Movies with release year: #{format_number(movies_with_year)}")

    if movies_with_year < total_movies do
      missing_year = total_movies - movies_with_year
      Mix.shell().info("  Movies without year data: #{format_number(missing_year)}")
    end

    # Show recent years detail
    Mix.shell().info("")
    Mix.shell().info("📈 RECENT YEARS DETAIL")

    recent_years =
      year_counts
      |> Enum.filter(fn {y, _} -> y && y >= 2020 end)
      |> Enum.sort_by(fn {y, _} -> y end, :desc)

    Enum.each(recent_years, fn {year, count} ->
      Mix.shell().info("  #{trunc(year)}: #{format_number(count)} movies")
    end)

    Mix.shell().info("")
    Mix.shell().info("💡 Tip: Run 'mix tmdb.export backfill' to import missing movies")
    Mix.shell().info("        Movies will fill into years as they are imported")
    Mix.shell().info("")
  end

  defp show_help do
    Mix.shell().info("""

    TMDb Export Commands
    ====================

    ANALYSIS
      mix tmdb.export download          Download today's export file
      mix tmdb.export download -d DATE  Download specific date (YYYY-MM-DD)
      mix tmdb.export analyze           Analyze export file contents
      mix tmdb.export analyze -v        Analyze with sample movies
      mix tmdb.export gap               Run full gap analysis vs database
      mix tmdb.export missing           Show missing movies
      mix tmdb.export missing -l 50     Show top 50 missing by popularity
      mix tmdb.export missing --by-tier Show missing grouped by tier
      mix tmdb.export year-status       Show year-by-year movie coverage
      mix tmdb.export year-status -l 50 Show top 50 years

    MANUAL BACKFILL (single batch)
      mix tmdb.export backfill -n           Preview what would be imported (dry run)
      mix tmdb.export backfill -l 100       Import 100 movies
      mix tmdb.export backfill --min-popularity 10  Only import popular movies
      mix tmdb.export backfill              Import ALL missing movies

    CONTINUOUS BACKFILL (automated, runs until complete) ⭐ RECOMMENDED
      mix tmdb.export continuous --start    Start continuous backfill
      mix tmdb.export continuous --status   Check progress (default)
      mix tmdb.export continuous --stop     Pause backfill
      mix tmdb.export continuous --resume   Resume paused backfill

    Options:
      -d, --date DATE           Specific date (YYYY-MM-DD)
      -l, --limit N             Limit results/imports
      -n, --dry-run             Preview without importing
      --min-popularity N        Filter by minimum popularity (default: 1.0 for continuous)
      --batch-size N            Jobs per batch (default: 100 manual, 10000 continuous)
      --offset N                Skip first N movies (for resuming manual)
      --by-tier                 Group missing by popularity tier
      -v, --verbose             Show more details

    Examples:
      # Start fully automated backfill (recommended)
      mix tmdb.export continuous --start

      # Start with custom batch size
      mix tmdb.export continuous --start --batch-size 5000

      # Check status
      mix tmdb.export continuous --status

      # Manual: Import 1000 movies at a time
      mix tmdb.export backfill --limit 1000

    """)
  end

  defp find_export_file(opts) do
    date =
      if opts[:date] do
        case Date.from_iso8601(opts[:date]) do
          {:ok, d} ->
            d

          {:error, _} ->
            Mix.shell().error(
              "Invalid date format '#{opts[:date]}', falling back to today's date"
            )

            Date.utc_today()
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
          {:ok, path} ->
            path

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
