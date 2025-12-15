defmodule Cinegraph.Repairs do
  @moduledoc """
  Context for detecting and repairing data quality issues.

  Provides detection queries for common data problems and
  coordinates with repair workers to fix them.
  """

  import Ecto.Query
  alias Cinegraph.Repo

  @doc """
  Detects all data quality issues and returns a list of issue maps.

  Each issue contains:
  - `:type` - The repair type identifier
  - `:title` - Human-readable title
  - `:description` - Explanation of the issue
  - `:count` - Number of affected records
  - `:examples` - Sample affected records (up to 5)
  """
  def detect_all_issues do
    [
      detect_missing_director_credits()
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Detects movies that are missing director credits.

  These are movies with a tmdb_id (so we can fetch from TMDb) but no
  credit record with department='Directing' and job='Director'.
  """
  def detect_missing_director_credits do
    count_query = """
    SELECT COUNT(*)
    FROM movies m
    WHERE m.tmdb_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM movie_credits mc
      WHERE mc.movie_id = m.id
      AND mc.department = 'Directing'
      AND mc.job = 'Director'
    )
    """

    examples_query = """
    SELECT m.id, m.title, m.tmdb_id
    FROM movies m
    WHERE m.tmdb_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM movie_credits mc
      WHERE mc.movie_id = m.id
      AND mc.department = 'Directing'
      AND mc.job = 'Director'
    )
    ORDER BY m.id DESC
    LIMIT 5
    """

    with {:ok, %{rows: [[count]]}} <- Repo.query(count_query),
         {:ok, %{rows: examples}} <- Repo.query(examples_query) do
      if count > 0 do
        %{
          type: "missing_director_credits",
          title: "Missing Director Credits",
          description: "Movies without director credits (needed for festival person inference)",
          count: count,
          examples:
            Enum.map(examples, fn [id, title, _tmdb_id] ->
              %{id: id, title: title}
            end)
        }
      else
        nil
      end
    else
      _ -> nil
    end
  end

  @doc """
  Gets the IDs of movies missing director credits, for use by the repair worker.

  Returns movies in batches, starting after `after_id`.
  """
  def get_movies_missing_directors(after_id \\ 0, limit \\ 100) do
    query = """
    SELECT m.id, m.tmdb_id, m.title
    FROM movies m
    WHERE m.tmdb_id IS NOT NULL
    AND m.id > $1
    AND NOT EXISTS (
      SELECT 1 FROM movie_credits mc
      WHERE mc.movie_id = m.id
      AND mc.department = 'Directing'
      AND mc.job = 'Director'
    )
    ORDER BY m.id ASC
    LIMIT $2
    """

    case Repo.query(query, [after_id, limit]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [id, tmdb_id, title] ->
          %{id: id, tmdb_id: tmdb_id, title: title}
        end)

      _ ->
        []
    end
  end

  @doc """
  Checks if a repair worker is currently running for the given type.
  """
  def repair_in_progress?(repair_type) do
    query =
      from(j in "oban_jobs",
        where: j.worker == "Cinegraph.Workers.DataRepairWorker",
        where: j.state in ["available", "executing", "scheduled"],
        where: fragment("?->>'repair_type' = ?", j.args, ^repair_type),
        select: count(j.id)
      )

    Repo.one(query) > 0
  end

  @doc """
  Gets the current progress of a running repair job.

  Returns nil if no job is running, otherwise returns the job's meta.
  """
  def get_repair_progress(repair_type) do
    query =
      from(j in "oban_jobs",
        where: j.worker == "Cinegraph.Workers.DataRepairWorker",
        where: j.state in ["available", "executing", "scheduled"],
        where: fragment("?->>'repair_type' = ?", j.args, ^repair_type),
        order_by: [desc: j.inserted_at],
        limit: 1,
        select: %{
          id: j.id,
          state: j.state,
          args: j.args,
          meta: j.meta,
          inserted_at: j.inserted_at
        }
      )

    Repo.one(query)
  end

  @doc """
  Starts a repair operation for the given type.
  """
  def start_repair("missing_director_credits") do
    if repair_in_progress?("missing_director_credits") do
      {:error, :already_running}
    else
      # Get total count for progress tracking
      case detect_missing_director_credits() do
        %{count: count} when count > 0 ->
          %{
            "repair_type" => "missing_director_credits",
            "last_id" => 0,
            "batch_size" => 50,
            "total" => count
          }
          |> Cinegraph.Workers.DataRepairWorker.new()
          |> Oban.insert()

        _ ->
          {:error, :nothing_to_repair}
      end
    end
  end

  def start_repair(_unknown_type) do
    {:error, :unknown_repair_type}
  end
end
