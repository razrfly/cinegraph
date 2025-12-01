defmodule Cinegraph.Workers.DailyYearImportWorker do
  @moduledoc """
  Daily orchestrator that imports movies year by year.

  This is the bootstrap phase to build the full TMDb catalog. Once complete,
  we'll switch to the Changes API for daily delta sync.

  Strategy:
  1. Start with current year, work backward
  2. Import one year per day (can be adjusted)
  3. Track progress via ImportStateV2
  4. Queue TMDbDiscoveryWorker jobs with year filter
  """

  use Oban.Worker,
    queue: :tmdb_orchestration,
    max_attempts: 3

  alias Cinegraph.Imports.ImportStateV2
  alias Cinegraph.Workers.TMDbDiscoveryWorker
  alias Cinegraph.Services.TMDb.Client
  require Logger

  @doc """
  Performs the daily year import.

  Can be triggered manually or via cron. Supports args:
  - "year" - Import a specific year (overrides auto-selection)
  - "force" - Force re-import even if year appears complete
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    # Check if a specific year was requested
    year = Map.get(args, "year") || get_next_year_to_import()
    force = Map.get(args, "force", false)

    Logger.info("DailyYearImportWorker starting for year #{year}")

    cond do
      year < 1888 ->
        # First film was in 1888, we're done
        Logger.info("All years imported! (reached year #{year})")
        ImportStateV2.set("bulk_import_complete", true)
        {:ok, :complete}

      not force and year_appears_complete?(year) ->
        Logger.info("Year #{year} appears complete, moving to next year")
        # Mark as complete and let next run handle the previous year
        mark_year_complete(year)
        {:ok, :year_already_complete}

      true ->
        queue_year_import(year)
    end
  end

  @doc """
  Gets the next year that needs to be imported.
  Starts with current year and works backward.
  """
  def get_next_year_to_import do
    current_year = Date.utc_today().year

    # Get the last completed year, default to current_year + 1 (meaning nothing completed yet)
    last_completed = ImportStateV2.get_integer("last_completed_year", current_year + 1)

    # Next year to import is one before the last completed
    last_completed - 1
  end

  @doc """
  Checks if a year appears to be complete by comparing our count to TMDb's count.
  Uses a threshold since counts may not match exactly (deleted movies, etc.)
  """
  def year_appears_complete?(year) do
    our_count = count_movies_for_year(year)
    tmdb_count = get_tmdb_count_for_year(year)

    # Consider complete if we have at least 95% of TMDb's count
    # or if TMDb shows 0 movies for that year
    case tmdb_count do
      0 -> true
      count when count > 0 -> our_count >= count * 0.95
      _ -> false
    end
  end

  @doc """
  Counts movies we have for a specific year.
  """
  def count_movies_for_year(year) do
    import Ecto.Query
    alias Cinegraph.{Repo, Movies.Movie}

    Repo.one(
      from(m in Movie,
        where: fragment("EXTRACT(YEAR FROM ?::date) = ?", m.release_date, ^year),
        select: count(m.id)
      )
    ) || 0
  end

  @doc """
  Gets the total movie count for a year from TMDb.
  """
  def get_tmdb_count_for_year(year) do
    case Client.get("/discover/movie", %{
           "primary_release_year" => year,
           "page" => 1
         }) do
      {:ok, %{"total_results" => total}} ->
        total

      {:error, reason} ->
        Logger.warning("Failed to get TMDb count for year #{year}: #{inspect(reason)}")
        0
    end
  end

  @doc """
  Queues the import jobs for a specific year.
  """
  def queue_year_import(year) do
    Logger.info("Queuing import for year #{year}")

    # First, get the total pages for this year
    case Client.get("/discover/movie", %{
           "primary_release_year" => year,
           "sort_by" => "popularity.desc",
           "page" => 1
         }) do
      {:ok, %{"total_pages" => total_pages, "total_results" => total_results}} ->
        Logger.info("Year #{year}: #{total_results} movies across #{total_pages} pages")

        # Track that we started this year
        ImportStateV2.set("current_import_year", year)
        ImportStateV2.set("year_#{year}_started_at", DateTime.utc_now() |> DateTime.to_iso8601())
        ImportStateV2.set("year_#{year}_total_movies", total_results)
        ImportStateV2.set("year_#{year}_total_pages", total_pages)

        # Queue all pages for this year
        # TMDb limits to 500 pages max
        pages_to_queue = min(total_pages, 500)

        jobs =
          for page <- 1..pages_to_queue do
            %{
              "page" => page,
              "primary_release_year" => year,
              "sort_by" => "popularity.desc",
              "import_type" => "year_import",
              "year" => year
            }
            |> TMDbDiscoveryWorker.new()
          end

        case Oban.insert_all(jobs) do
          inserted when is_list(inserted) ->
            Logger.info("Queued #{length(inserted)} discovery jobs for year #{year}")

            # Queue completion checker
            queue_completion_checker(year, pages_to_queue)

            {:ok, %{year: year, pages_queued: length(inserted), total_movies: total_results}}

          error ->
            Logger.error("Failed to queue discovery jobs: #{inspect(error)}")
            {:error, error}
        end

      {:error, reason} ->
        Logger.error("Failed to get movie count for year #{year}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Queues a completion checker that will mark the year complete when all jobs are done.
  """
  def queue_completion_checker(year, expected_pages) do
    %{
      "year" => year,
      "expected_pages" => expected_pages
    }
    |> Cinegraph.Workers.YearImportCompletionWorker.new(schedule_in: 300)
    |> Oban.insert()
  end

  @doc """
  Marks a year as complete.
  """
  def mark_year_complete(year) do
    movie_count = count_movies_for_year(year)

    ImportStateV2.set("last_completed_year", year)
    ImportStateV2.set("year_#{year}_completed_at", DateTime.utc_now() |> DateTime.to_iso8601())
    ImportStateV2.set("year_#{year}_movie_count", movie_count)

    Logger.info("Marked year #{year} as complete with #{movie_count} movies")
  end

  @doc """
  Manual trigger to import a specific year.
  Useful for testing or re-importing a year.

  ## Examples

      iex> DailyYearImportWorker.import_year(2024)
      {:ok, %{year: 2024, pages_queued: 150, total_movies: 28432}}

      iex> DailyYearImportWorker.import_year(2023, force: true)
      {:ok, %{year: 2023, pages_queued: 175, total_movies: 31205}}
  """
  def import_year(year, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    %{"year" => year, "force" => force}
    |> new()
    |> Oban.insert()
  end
end
