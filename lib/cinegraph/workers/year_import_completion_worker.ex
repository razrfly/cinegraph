defmodule Cinegraph.Workers.YearImportCompletionWorker do
  @moduledoc """
  Monitors the progress of a year import and marks it complete when all jobs finish.

  This worker is queued by DailyYearImportWorker after queuing all discovery jobs
  for a year. It periodically checks if all jobs are done and then marks the year
  as complete.
  """

  use Oban.Worker,
    queue: :tmdb,
    max_attempts: 20

  alias Cinegraph.Imports.ImportStateV2
  alias Cinegraph.Workers.DailyYearImportWorker
  alias Cinegraph.Repo
  import Ecto.Query
  require Logger

  @doc """
  Checks if all discovery jobs for a year are complete.
  If not, reschedules itself to check again later.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"year" => year} = args}) do
    expected_pages = Map.get(args, "expected_pages", 0)

    # Count pending/executing jobs for this year
    {pending, executing, completed, failed} = count_jobs_for_year(year)

    total_processed = completed + failed
    remaining = pending + executing

    Logger.info(
      "Year #{year} import status: #{completed} completed, #{failed} failed, " <>
        "#{executing} executing, #{pending} pending (#{remaining} remaining)"
    )

    cond do
      remaining == 0 and total_processed > 0 ->
        # All jobs done, mark year complete
        Logger.info("Year #{year} import complete! #{completed} successful, #{failed} failed")
        DailyYearImportWorker.mark_year_complete(year)

        # Broadcast completion
        Phoenix.PubSub.broadcast(
          Cinegraph.PubSub,
          "import_progress",
          {:year_import_complete,
           %{
             year: year,
             completed: completed,
             failed: failed,
             movie_count: DailyYearImportWorker.count_movies_for_year(year)
           }}
        )

        {:ok, :year_complete}

      remaining > 0 ->
        # Still jobs running, check again in 5 minutes
        progress_pct =
          if expected_pages > 0,
            do: Float.round(total_processed / expected_pages * 100, 1),
            else: 0.0

        Logger.info("Year #{year}: #{progress_pct}% complete, rechecking in 5 minutes")

        # Update progress state
        ImportStateV2.set("year_#{year}_progress", progress_pct)

        # Snooze to check again (Oban will re-run this job)
        {:snooze, 300}

      true ->
        # No jobs found at all - might have been cleared or never started
        Logger.warning("No jobs found for year #{year}, checking if we have movies")

        movie_count = DailyYearImportWorker.count_movies_for_year(year)

        if movie_count > 0 do
          Logger.info("Year #{year} has #{movie_count} movies, marking complete")
          DailyYearImportWorker.mark_year_complete(year)
          {:ok, :year_complete}
        else
          Logger.warning("Year #{year} has no movies and no jobs - may need manual intervention")
          {:ok, :no_jobs_found}
        end
    end
  end

  @doc """
  Counts jobs for a specific year by state.
  Returns {pending, executing, completed, failed}
  """
  def count_jobs_for_year(year) do
    # Query Oban jobs table for year_import jobs for this specific year
    # Jobs have args like %{"year" => 2024, "import_type" => "year_import"}

    base_query =
      from(j in Oban.Job,
        where:
          j.worker == "Cinegraph.Workers.TMDbDiscoveryWorker" and
            fragment("?->>'import_type' = 'year_import'", j.args) and
            fragment("(?->>'year')::int = ?", j.args, ^year)
      )

    pending =
      Repo.one(from(j in base_query, where: j.state == "available", select: count(j.id))) || 0

    scheduled =
      Repo.one(from(j in base_query, where: j.state == "scheduled", select: count(j.id))) || 0

    retryable =
      Repo.one(from(j in base_query, where: j.state == "retryable", select: count(j.id))) || 0

    executing =
      Repo.one(from(j in base_query, where: j.state == "executing", select: count(j.id))) || 0

    completed =
      Repo.one(from(j in base_query, where: j.state == "completed", select: count(j.id))) || 0

    failed =
      Repo.one(
        from(j in base_query, where: j.state in ["discarded", "cancelled"], select: count(j.id))
      ) || 0

    {pending + scheduled + retryable, executing, completed, failed}
  end
end
