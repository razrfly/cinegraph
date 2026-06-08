defmodule Cinegraph.Workers.DataRepairWorker do
  @moduledoc """
  Background worker for repairing data quality issues.

  Supports:
  - missing_director_credits: Fetches credits from TMDb for movies missing director data
  - extract_jsonb_credits: Extracts credits from tmdb_data JSONB into movie_credits table
    (fixes issue #550 where ~56K movies have credits in JSONB but not in the credits table)
  - backfill_external_metrics_omdb / backfill_external_metrics_tmdb: Re-runs
    ExternalMetric.from_omdb/2 and from_tmdb/2 against existing JSONB blobs to
    fill external_metrics rows that were missed when the extractor was added
    after the catalog was already ingested. Idempotent via on_conflict: :nothing
    on the (movie_id, source, metric_type) unique index (#913 Session 1).
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    # Compare full args for uniqueness - allows batched jobs with different last_id
    unique: [period: 600]

  alias Cinegraph.{Repo, Movies, Repairs}
  alias Cinegraph.Movies.ExternalMetric
  alias Cinegraph.Services.TMDb
  import Ecto.Query
  require Logger

  @batch_size 50
  @rate_limit_delay 250
  @jsonb_batch_size 100
  @metrics_backfill_batch_size 200
  # Throttle between batches so we don't re-create the OOM pressure from #910.
  @metrics_backfill_delay 500

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"repair_type" => "missing_director_credits"} = args} = job) do
    last_id = args["last_id"] || 0
    batch_size = args["batch_size"] || @batch_size
    total = args["total"] || 0

    Logger.info("DataRepairWorker: Processing batch after id #{last_id}")

    # Get batch of movies missing directors
    movies = Repairs.get_movies_missing_directors(last_id, batch_size)

    if movies == [] do
      # Done!
      update_job_meta(job, %{
        status: "completed",
        processed: last_id,
        total: total,
        completed_at: DateTime.utc_now()
      })

      Logger.info("DataRepairWorker: Completed missing_director_credits repair")
      :ok
    else
      # Process this batch
      {success_count, error_count} = process_batch(movies)

      # Get the last ID processed
      new_last_id = List.last(movies).id

      # Update progress
      update_job_meta(job, %{
        status: "in_progress",
        last_id: new_last_id,
        batch_success: success_count,
        batch_errors: error_count,
        total: total
      })

      Logger.info(
        "DataRepairWorker: Batch complete. Success: #{success_count}, Errors: #{error_count}"
      )

      # Schedule next batch
      schedule_next_batch(args, new_last_id)
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"repair_type" => "extract_jsonb_credits"} = args} = job) do
    last_id = args["last_id"] || 0
    batch_size = args["batch_size"] || @jsonb_batch_size
    total_processed = args["total_processed"] || 0

    Logger.info("DataRepairWorker: Extracting JSONB credits, batch after id #{last_id}")

    # Get batch of movies with credits in tmdb_data but not in movie_credits
    case get_movies_with_unextracted_credits(last_id, batch_size) do
      {:error, reason} ->
        Logger.error("DataRepairWorker: Query failed, will retry: #{inspect(reason)}")
        {:error, reason}

      [] ->
        # Done!
        update_job_meta(job, %{
          status: "completed",
          total_processed: total_processed,
          completed_at: DateTime.utc_now()
        })

        Logger.info(
          "DataRepairWorker: Completed extract_jsonb_credits repair. Total: #{total_processed}"
        )

        :ok

      movies ->
        # Process this batch
        {success_count, error_count, credits_created} = process_jsonb_batch(movies)

        # Get the last ID processed
        new_last_id = List.last(movies).id
        new_total = total_processed + success_count

        # Update progress
        update_job_meta(job, %{
          status: "in_progress",
          last_id: new_last_id,
          batch_success: success_count,
          batch_errors: error_count,
          batch_credits_created: credits_created,
          total_processed: new_total
        })

        Logger.info(
          "DataRepairWorker: JSONB batch complete. Movies: #{success_count}, Credits: #{credits_created}, Errors: #{error_count}"
        )

        # Schedule next batch
        schedule_next_batch(
          %{args | "total_processed" => new_total},
          new_last_id
        )
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"repair_type" => "backfill_external_metrics_omdb"} = args} = job) do
    process_metric_backfill_batch(job, args, :omdb)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"repair_type" => "backfill_external_metrics_tmdb"} = args} = job) do
    process_metric_backfill_batch(job, args, :tmdb)
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("DataRepairWorker: Unknown repair type: #{inspect(args)}")
    {:error, "Unknown repair type"}
  end

  defp process_batch(movies) do
    movies
    |> Enum.reduce({0, 0}, fn movie, {success, errors} ->
      # Rate limiting
      Process.sleep(@rate_limit_delay)

      case fetch_and_store_credits(movie) do
        :ok ->
          {success + 1, errors}

        {:error, reason} ->
          Logger.warning(
            "DataRepairWorker: Failed to fetch credits for movie #{movie.id} (#{movie.title}): #{inspect(reason)}"
          )

          {success, errors + 1}
      end
    end)
  end

  defp fetch_and_store_credits(%{tmdb_id: tmdb_id, id: movie_id, title: title}) do
    Logger.debug("DataRepairWorker: Fetching credits for #{title} (TMDb: #{tmdb_id})")

    # Fetch movie data with credits from TMDb
    case TMDb.get_movie(tmdb_id, append_to_response: "credits") do
      {:ok, %{"credits" => credits}} when is_map(credits) ->
        # Get the movie struct
        movie = Repo.get!(Movies.Movie, movie_id)

        # Process credits using existing function - this will create person records and credits
        Movies.process_movie_credits_public(movie, credits)

        Logger.info("DataRepairWorker: Updated credits for #{title}")
        :ok

      {:ok, data} ->
        Logger.warning(
          "DataRepairWorker: No credits in response for #{title}: #{inspect(Map.keys(data))}"
        )

        {:error, :no_credits_in_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp schedule_next_batch(args, new_last_id) do
    base = %{
      "repair_type" => args["repair_type"],
      "last_id" => new_last_id,
      "batch_size" => args["batch_size"] || @batch_size,
      "total" => args["total"]
    }

    # Propagate JSONB-specific keys when present
    base =
      Enum.reduce(~w(total_processed total_estimated), base, fn key, acc ->
        case args[key] do
          nil -> acc
          val -> Map.put(acc, key, val)
        end
      end)

    base
    |> __MODULE__.new(schedule_in: 5)
    |> Oban.insert()

    :ok
  end

  defp update_job_meta(job, meta) do
    from(j in "oban_jobs",
      where: j.id == ^job.id,
      update: [set: [meta: ^meta]]
    )
    |> Repo.update_all([])
  rescue
    error ->
      Logger.warning("DataRepairWorker: Failed to update job meta: #{inspect(error)}")
  end

  # ============================================================================
  # JSONB Credits Extraction (Issue #550)
  # ============================================================================

  @doc """
  Finds movies that have credits in tmdb_data JSONB but no entries in movie_credits table.
  Uses NOT EXISTS for better performance than LEFT JOIN NULL check.
  """
  def get_movies_with_unextracted_credits(last_id, limit) do
    alias Cinegraph.Movies.Movie

    # Use NOT EXISTS which is often faster than LEFT JOIN for this pattern
    id_query = """
    SELECT m.id
    FROM movies m
    WHERE m.id > $1
      AND m.import_status = 'full'
      AND m.tmdb_data IS NOT NULL
      AND (m.tmdb_data->'credits'->'cast') IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM movie_credits c WHERE c.movie_id = m.id
      )
    ORDER BY m.id
    LIMIT $2
    """

    case Repo.query(id_query, [last_id, limit], timeout: 120_000) do
      {:ok, %{rows: rows}} when rows != [] ->
        ids = Enum.map(rows, fn [id] -> id end)

        # Fetch full movie data for those IDs
        from(m in Movie,
          where: m.id in ^ids,
          order_by: [asc: m.id],
          select: %{
            id: m.id,
            title: m.title,
            tmdb_data: m.tmdb_data
          }
        )
        |> Repo.all()

      {:ok, %{rows: []}} ->
        []

      {:error, reason} ->
        Logger.error("DataRepairWorker: Failed to query unextracted credits: #{inspect(reason)}")

        {:error, reason}
    end
  end

  @doc """
  Counts total movies with unextracted credits for progress tracking.
  Uses NOT EXISTS for better performance than LEFT JOIN NULL check.
  """
  def count_movies_with_unextracted_credits do
    query = """
    SELECT COUNT(*)
    FROM movies m
    WHERE m.import_status = 'full'
      AND m.tmdb_data IS NOT NULL
      AND (m.tmdb_data->'credits'->'cast') IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM movie_credits c WHERE c.movie_id = m.id
      )
    """

    case Repo.query(query, [], timeout: 120_000) do
      {:ok, %{rows: [[count]]}} -> count
      {:error, _} -> 0
    end
  end

  defp process_jsonb_batch(movies) do
    movies
    |> Enum.reduce({0, 0, 0}, fn movie_data, {success, errors, credits} ->
      case extract_credits_from_jsonb(movie_data) do
        {:ok, credit_count} ->
          {success + 1, errors, credits + credit_count}

        {:error, reason} ->
          Logger.warning(
            "DataRepairWorker: Failed to extract credits for movie #{movie_data.id} (#{movie_data.title}): #{inspect(reason)}"
          )

          {success, errors + 1, credits}
      end
    end)
  end

  defp extract_credits_from_jsonb(%{id: movie_id, title: title, tmdb_data: tmdb_data}) do
    credits_data = tmdb_data["credits"]

    if credits_data && (credits_data["cast"] || credits_data["crew"]) do
      # Get the movie struct
      movie = Repo.get!(Movies.Movie, movie_id)

      # Count credits before
      before_count = count_movie_credits(movie_id)

      try do
        # Process credits using existing function
        Movies.process_movie_credits_public(movie, credits_data)

        # Count credits after
        after_count = count_movie_credits(movie_id)
        credits_created = after_count - before_count

        Logger.debug("DataRepairWorker: Extracted #{credits_created} credits for #{title}")

        {:ok, credits_created}
      rescue
        e ->
          Logger.error(
            "DataRepairWorker: Crash extracting credits for movie #{movie_id} (#{title}): #{inspect(e)}"
          )

          {:error, {:extraction_crash, e}}
      end
    else
      {:error, :no_credits_in_jsonb}
    end
  end

  defp count_movie_credits(movie_id) do
    alias Cinegraph.Movies.Credit

    from(c in Credit, where: c.movie_id == ^movie_id)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Starts the JSONB credits extraction job.

  ## Example

      DataRepairWorker.start_jsonb_credits_extraction()
  """
  def start_jsonb_credits_extraction(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @jsonb_batch_size)

    total = count_movies_with_unextracted_credits()
    Logger.info("DataRepairWorker: Starting JSONB credits extraction for #{total} movies")

    %{
      "repair_type" => "extract_jsonb_credits",
      "batch_size" => batch_size,
      "total_estimated" => total,
      "total_processed" => 0
    }
    |> __MODULE__.new()
    |> Oban.insert()
  end

  # ============================================================================
  # External Metrics Backfill (#913 Session 1)
  # ============================================================================

  defp process_metric_backfill_batch(job, args, source) when source in [:omdb, :tmdb] do
    last_id = args["last_id"] || 0
    batch_size = args["batch_size"] || @metrics_backfill_batch_size
    total_processed = args["total_processed"] || 0
    total_inserted = args["total_inserted"] || 0
    source_label = Atom.to_string(source)

    Logger.info(
      "DataRepairWorker: external_metrics backfill (#{source_label}), batch after id #{last_id}"
    )

    case get_movies_with_jsonb(source, last_id, batch_size) do
      [] ->
        update_job_meta(job, %{
          status: "completed",
          total_processed: total_processed,
          total_inserted: total_inserted,
          completed_at: DateTime.utc_now()
        })

        Logger.info(
          "DataRepairWorker: Completed external_metrics backfill (#{source_label}). " <>
            "Scanned: #{total_processed}, inserted: #{total_inserted}."
        )

        :ok

      movies ->
        {inserted, scanned} = process_metric_batch(movies, source)
        new_last_id = List.last(movies).id
        new_total_processed = total_processed + scanned
        new_total_inserted = total_inserted + inserted

        update_job_meta(job, %{
          status: "in_progress",
          last_id: new_last_id,
          batch_scanned: scanned,
          batch_inserted: inserted,
          total_processed: new_total_processed,
          total_inserted: new_total_inserted
        })

        Logger.info(
          "DataRepairWorker: external_metrics batch (#{source_label}) — " <>
            "scanned #{scanned}, inserted #{inserted} (cumulative inserted #{new_total_inserted})"
        )

        # Throttle between batches so the replica is not hammered.
        Process.sleep(@metrics_backfill_delay)

        schedule_next_batch(
          args
          |> Map.put("total_processed", new_total_processed)
          |> Map.put("total_inserted", new_total_inserted),
          new_last_id
        )
    end
  end

  defp get_movies_with_jsonb(:omdb, last_id, limit) do
    from(m in Movies.Movie,
      where: m.id > ^last_id,
      where: not is_nil(m.omdb_data),
      order_by: [asc: m.id],
      limit: ^limit,
      select: %{id: m.id, omdb_data: m.omdb_data}
    )
    |> Repo.all(timeout: 60_000)
  end

  defp get_movies_with_jsonb(:tmdb, last_id, limit) do
    from(m in Movies.Movie,
      where: m.id > ^last_id,
      where: not is_nil(m.tmdb_data),
      order_by: [asc: m.id],
      limit: ^limit,
      select: %{id: m.id, tmdb_data: m.tmdb_data}
    )
    |> Repo.all(timeout: 60_000)
  end

  defp process_metric_batch(movies, source) do
    # `inserted_at`/`updated_at` come from `timestamps()` → :naive_datetime. `insert_all`
    # does NO casting, so a DateTime here raises Ecto.ChangeError and the whole backfill
    # discards (this silently broke the #1053 materialization since #1054 — debt never moved).
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      movies
      |> Enum.flat_map(fn movie ->
        movie
        |> extract_metric_rows(source)
        |> Enum.map(fn row ->
          row
          # `from_omdb`/`from_tmdb` shape rows for the CHANGESET path, which casts. `insert_all`
          # does not — so `value` arrives as an integer (e.g. imdbVotes) against a :float column
          # and raises. Coerce here so the materialization matches the column types exactly.
          |> Map.update(:value, nil, fn
            v when is_integer(v) -> v * 1.0
            v -> v
          end)
          |> Map.put(:inserted_at, now)
          |> Map.put(:updated_at, now)
        end)
      end)

    scanned = length(movies)

    inserted =
      case rows do
        [] ->
          0

        rows ->
          {count, _} =
            Repo.insert_all(ExternalMetric, rows,
              on_conflict: :nothing,
              conflict_target: [:movie_id, :source, :metric_type]
            )

          count
      end

    {inserted, scanned}
  end

  defp extract_metric_rows(%{id: movie_id, omdb_data: data}, :omdb) when is_map(data),
    do: ExternalMetric.from_omdb(movie_id, data)

  defp extract_metric_rows(%{id: movie_id, tmdb_data: data}, :tmdb) when is_map(data),
    do: ExternalMetric.from_tmdb(movie_id, data)

  defp extract_metric_rows(_movie, _source), do: []

  @doc """
  Starts the external_metrics backfill for a given source (#913 Session 1).

  Re-runs `ExternalMetric.from_omdb/2` (or `from_tmdb/2`) against every movie
  with the corresponding JSONB blob populated, inserting any missing rows.
  Idempotent — existing rows are skipped via the unique index on
  `(movie_id, source, metric_type)`.

  ## Example

      Cinegraph.Workers.DataRepairWorker.start_external_metrics_backfill(:omdb)
      Cinegraph.Workers.DataRepairWorker.start_external_metrics_backfill(:tmdb, batch_size: 100)
  """
  def start_external_metrics_backfill(source, opts \\ []) when source in [:omdb, :tmdb] do
    batch_size = Keyword.get(opts, :batch_size, @metrics_backfill_batch_size)
    repair_type = "backfill_external_metrics_#{source}"

    Logger.info(
      "DataRepairWorker: enqueuing external_metrics backfill for #{source} (batch_size=#{batch_size})"
    )

    %{
      "repair_type" => repair_type,
      "batch_size" => batch_size,
      "last_id" => 0,
      "total_processed" => 0,
      "total_inserted" => 0
    }
    |> __MODULE__.new()
    |> Oban.insert()
  end
end
