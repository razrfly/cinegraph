defmodule Cinegraph.Collaborations do
  @moduledoc """
  The Collaborations context handles actor-director and other collaboration relationships.
  """

  import Ecto.Query, warn: false
  require Logger
  alias Cinegraph.Repo
  alias Cinegraph.Collaborations.{Collaboration, CollaborationDetail}
  alias Cinegraph.Movies.{Movie, Person}
  alias Cinegraph.Workers.CollaborationWorker

  @key_crew_jobs [
    "Director",
    "Producer",
    "Executive Producer",
    "Screenplay",
    "Writer",
    "Director of Photography",
    "Original Music Composer",
    "Editor"
  ]

  @doc """
  The crew jobs that, alongside the top-20 cast and directors, define the "key people" scope the
  collaboration graph (and the `person_collaboration_trends` matview) is built on. Exposed so
  derived prediction features can reuse the same person scope instead of copying the list.
  """
  def key_crew_jobs, do: @key_crew_jobs

  @doc """
  Populates the collaborations table from existing movie credits.
  This should be run after importing movies.
  """
  def populate_collaborations do
    # Read movie IDs from replica BEFORE transaction (replica reads can't participate in transactions)
    movie_ids = Repo.replica().all(from m in Movie, select: m.id)

    Repo.transaction(fn ->
      # Clear existing data
      Repo.delete_all(CollaborationDetail)
      Repo.delete_all(Collaboration)

      case populate_key_collaborations_only(movie_ids) do
        {:ok, count} -> count
        other -> Repo.rollback(other)
      end
    end)
  end

  @doc """
  Populates collaborations for a single movie.
  This is more efficient for incremental updates.
  """
  def populate_movie_collaborations(movie_id), do: rebuild_movie_collaborations(movie_id)

  @doc """
  Enqueues an idempotent collaboration rebuild for a movie.

  This is deliberately best-effort: collaboration materialization should heal in
  the background without failing the movie import or credit repair that requested it.
  """
  def enqueue_movie_rebuild(%Movie{id: movie_id}), do: enqueue_movie_rebuild(movie_id)

  def enqueue_movie_rebuild(movie_id) when is_integer(movie_id) do
    %{"movie_id" => movie_id}
    |> CollaborationWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to enqueue collaboration rebuild for movie #{movie_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  @doc """
  Rebuilds collaboration facts and aggregates for a single movie.

  This is idempotent: running it repeatedly for the same unchanged movie produces
  the same `collaboration_details` rows and aggregate `collaborations` counts.
  """
  def rebuild_movie_collaborations(movie_id) do
    Repo.transaction(fn ->
      desired_details = derive_movie_collaboration_details(movie_id)

      existing_pairs =
        movie_id
        |> existing_pairs_for_movie()
        |> MapSet.new()

      desired_pairs =
        desired_details
        |> Enum.map(&{&1.person_a_id, &1.person_b_id})
        |> MapSet.new()

      affected_pairs =
        existing_pairs
        |> MapSet.union(desired_pairs)
        |> MapSet.to_list()

      from(cd in CollaborationDetail, where: cd.movie_id == ^movie_id)
      |> Repo.delete_all()

      detail_count =
        desired_details
        |> Enum.reduce(0, fn detail, count ->
          collaboration = ensure_collaboration!(detail.person_a_id, detail.person_b_id)

          detail_attrs =
            detail
            |> Map.take([
              :movie_id,
              :year,
              :collaboration_type,
              :movie_rating,
              :movie_revenue
            ])
            |> Map.put(:collaboration_id, collaboration.id)

          %CollaborationDetail{}
          |> CollaborationDetail.changeset(detail_attrs)
          |> Repo.insert!()

          count + 1
        end)

      Enum.each(affected_pairs, fn {person_a_id, person_b_id} ->
        recompute_collaboration_aggregate!(person_a_id, person_b_id)
      end)

      %{
        movie_id: movie_id,
        details: detail_count,
        affected_pairs: length(affected_pairs)
      }
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp derive_movie_collaboration_details(movie_id) do
    case Repo.query(movie_collaboration_details_query(), [movie_id | @key_crew_jobs]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [
                            person_a_id,
                            person_b_id,
                            movie_id,
                            collaboration_type,
                            year,
                            vote_average,
                            revenue,
                            _release_date
                          ] ->
          %{
            person_a_id: person_a_id,
            person_b_id: person_b_id,
            movie_id: movie_id,
            collaboration_type: collaboration_type,
            year: year,
            movie_rating: vote_average,
            movie_revenue: integer_or_nil(revenue)
          }
        end)

      {:error, error} ->
        Repo.rollback({:query_error, error})
    end
  end

  defp existing_pairs_for_movie(movie_id) do
    from(cd in CollaborationDetail,
      join: c in Collaboration,
      on: c.id == cd.collaboration_id,
      where: cd.movie_id == ^movie_id,
      select: {c.person_a_id, c.person_b_id}
    )
    |> Repo.all()
  end

  defp ensure_collaboration!(person_a_id, person_b_id) do
    case Repo.get_by(Collaboration, person_a_id: person_a_id, person_b_id: person_b_id) do
      nil ->
        %Collaboration{}
        |> Collaboration.changeset(%{
          person_a_id: person_a_id,
          person_b_id: person_b_id,
          collaboration_count: 0,
          total_revenue: 0,
          years_active: []
        })
        |> Repo.insert(
          on_conflict: :nothing,
          conflict_target: [:person_a_id, :person_b_id]
        )
        |> case do
          {:ok, %Collaboration{id: nil}} ->
            Repo.get_by!(Collaboration, person_a_id: person_a_id, person_b_id: person_b_id)

          {:ok, collaboration} ->
            collaboration

          {:error, changeset} ->
            raise "Failed to insert collaboration: #{inspect(changeset.errors)}"
        end

      collaboration ->
        collaboration
    end
  end

  defp recompute_collaboration_aggregate!(person_a_id, person_b_id) do
    collaboration =
      Repo.get_by!(Collaboration, person_a_id: person_a_id, person_b_id: person_b_id)

    query = """
    WITH per_movie AS (
      SELECT
        cd.movie_id,
        MAX(cd.year) AS year,
        MAX(m.release_date) AS release_date,
        AVG(cd.movie_rating) AS movie_rating,
        MAX(cd.movie_revenue) AS movie_revenue
      FROM collaboration_details cd
      JOIN movies m ON m.id = cd.movie_id
      WHERE cd.collaboration_id = $1
      GROUP BY cd.movie_id
    )
    SELECT
      COUNT(*)::integer AS collaboration_count,
      MIN(release_date) AS first_collaboration_date,
      MAX(release_date) AS latest_collaboration_date,
      AVG(movie_rating) AS avg_movie_rating,
      COALESCE(SUM(movie_revenue), 0)::bigint AS total_revenue,
      COALESCE(ARRAY_AGG(DISTINCT year ORDER BY year) FILTER (WHERE year IS NOT NULL), '{}') AS years_active
    FROM per_movie
    """

    case Repo.query(query, [collaboration.id]) do
      {:ok, %{rows: [[0, nil, nil, nil, _total_revenue, _years_active]]}} ->
        Repo.delete!(collaboration)

      {:ok,
       %{
         rows: [
           [
             collaboration_count,
             first_collaboration_date,
             latest_collaboration_date,
             avg_movie_rating,
             total_revenue,
             years_active
           ]
         ]
       }} ->
        collaboration
        |> Collaboration.changeset(%{
          collaboration_count: collaboration_count,
          first_collaboration_date: first_collaboration_date,
          latest_collaboration_date: latest_collaboration_date,
          avg_movie_rating: avg_movie_rating,
          total_revenue: total_revenue || 0,
          years_active: years_active || []
        })
        |> Repo.update!()

      {:error, error} ->
        Repo.rollback({:query_error, error})
    end
  end

  defp movie_collaboration_details_query do
    """
    WITH person_pairs AS (
      SELECT DISTINCT
        LEAST(mc1.person_id, mc2.person_id) as person_a_id,
        GREATEST(mc1.person_id, mc2.person_id) as person_b_id,
        mc1.movie_id,
        m.release_date,
        m.vote_average,
        m.revenue,
        EXTRACT(YEAR FROM m.release_date)::INTEGER as year,
        CASE
          WHEN mc1.credit_type = 'cast' AND mc2.credit_type = 'cast' THEN 'actor-actor'
          WHEN mc1.credit_type = 'cast' AND mc2.job = 'Director' THEN 'actor-director'
          WHEN mc1.job = 'Director' AND mc2.credit_type = 'cast' THEN 'actor-director'
          WHEN mc1.job = 'Director' AND mc2.job = 'Director' THEN 'director-director'
          WHEN mc1.job = 'Director' AND mc2.job IN ($2, $3, $4, $5, $6, $7, $8, $9) THEN 'director-crew'
          WHEN mc1.job IN ($2, $3, $4, $5, $6, $7, $8, $9) AND mc2.job = 'Director' THEN 'director-crew'
          WHEN mc1.job IN ($2, $3, $4, $5, $6, $7, $8, $9) AND mc2.job IN ($2, $3, $4, $5, $6, $7, $8, $9) THEN 'crew-crew'
          ELSE 'other'
        END as collaboration_type
      FROM movie_credits mc1
      JOIN movie_credits mc2 ON mc1.movie_id = mc2.movie_id
      JOIN movies_with_metrics m ON mc1.movie_id = m.id
      WHERE mc1.person_id != mc2.person_id
        AND m.release_date IS NOT NULL
        AND m.id = $1
        AND (
          (mc1.credit_type = 'cast' AND mc2.credit_type = 'cast'
           AND mc1.cast_order <= 20 AND mc2.cast_order <= 20)
          OR
          (mc1.credit_type = 'cast' AND mc1.cast_order <= 20 AND mc2.job = 'Director')
          OR
          (mc1.job = 'Director' AND mc2.credit_type = 'cast' AND mc2.cast_order <= 20)
          OR
          (mc1.job = 'Director' AND mc2.job = 'Director')
          OR
          (mc1.job = 'Director' AND mc2.job IN ($2, $3, $4, $5, $6, $7, $8, $9))
          OR
          (mc1.job IN ($2, $3, $4, $5, $6, $7, $8, $9) AND mc2.job = 'Director')
          OR
          (mc1.job IN ($2, $3, $4, $5, $6, $7, $8, $9) AND mc2.job IN ($2, $3, $4, $5, $6, $7, $8, $9))
        )
    )
    SELECT
      person_a_id,
      person_b_id,
      movie_id,
      collaboration_type,
      year,
      vote_average,
      revenue,
      release_date
    FROM person_pairs
    """
  end

  defp integer_or_nil(nil), do: nil
  defp integer_or_nil(%Decimal{} = value), do: value |> Decimal.round(0) |> Decimal.to_integer()
  defp integer_or_nil(value) when is_float(value), do: trunc(value)
  defp integer_or_nil(value) when is_integer(value), do: value

  @doc """
  Populates only key collaborations: top 20 cast + directors + key crew.
  This prevents exponential explosion from movies with 1000+ credits.

  Accepts optional movie_ids list. If not provided, fetches all movie IDs from replica.
  """
  def populate_key_collaborations_only(movie_ids \\ nil) do
    IO.puts("Populating key collaborations (top 20 cast + directors + key crew)...")

    key_crew_jobs = @key_crew_jobs

    # Use provided movie_ids or fetch from replica (when called directly, not from transaction)
    movie_ids = movie_ids || Repo.replica().all(from m in Movie, select: m.id)
    total_movies = length(movie_ids)

    # Process movies in batches
    batch_size = 10

    _collaboration_count =
      movie_ids
      |> Enum.chunk_every(batch_size)
      |> Enum.with_index(1)
      |> Enum.reduce(0, fn {movie_batch, batch_num}, acc_count ->
        IO.puts("Processing batch #{batch_num}/#{ceil(total_movies / batch_size)}...")

        # Find all unique person pairs who worked together in this batch of movies
        # LIMITED TO: Top 20 cast + Directors + Key Crew
        collaborations_query = """
        WITH person_pairs AS (
          SELECT DISTINCT
            LEAST(mc1.person_id, mc2.person_id) as person_a_id,
            GREATEST(mc1.person_id, mc2.person_id) as person_b_id,
            mc1.movie_id,
            m.release_date,
            m.vote_average,
            m.revenue,
            EXTRACT(YEAR FROM m.release_date)::INTEGER as year,
            CASE 
              WHEN mc1.credit_type = 'cast' AND mc2.credit_type = 'cast' THEN 'actor-actor'
              WHEN mc1.credit_type = 'cast' AND mc2.job = 'Director' THEN 'actor-director'
              WHEN mc1.job = 'Director' AND mc2.credit_type = 'cast' THEN 'actor-director'
              WHEN mc1.job = 'Director' AND mc2.job = 'Director' THEN 'director-director'
              WHEN mc1.job = 'Director' AND mc2.job IN ($2, $3, $4, $5, $6, $7, $8, $9) THEN 'director-crew'
              WHEN mc1.job IN ($2, $3, $4, $5, $6, $7, $8, $9) AND mc2.job = 'Director' THEN 'director-crew'
              WHEN mc1.job IN ($2, $3, $4, $5, $6, $7, $8, $9) AND mc2.job IN ($2, $3, $4, $5, $6, $7, $8, $9) THEN 'crew-crew'
              ELSE 'other'
            END as collaboration_type
          FROM movie_credits mc1
          JOIN movie_credits mc2 ON mc1.movie_id = mc2.movie_id
          JOIN movies_with_metrics m ON mc1.movie_id = m.id
          WHERE mc1.person_id != mc2.person_id
            AND m.release_date IS NOT NULL
            AND m.id = ANY($1)
            AND (
              -- Top 20 cast members with each other
              (mc1.credit_type = 'cast' AND mc2.credit_type = 'cast' 
               AND mc1.cast_order <= 20 AND mc2.cast_order <= 20)
              OR
              -- Top 20 cast with directors
              (mc1.credit_type = 'cast' AND mc1.cast_order <= 20 AND mc2.job = 'Director')
              OR
              (mc1.job = 'Director' AND mc2.credit_type = 'cast' AND mc2.cast_order <= 20)
              OR
              -- Directors with other directors
              (mc1.job = 'Director' AND mc2.job = 'Director')
              OR
              -- Directors with key crew
              (mc1.job = 'Director' AND mc2.job IN ($2, $3, $4, $5, $6, $7, $8, $9))
              OR
              (mc1.job IN ($2, $3, $4, $5, $6, $7, $8, $9) AND mc2.job = 'Director')
              OR
              -- Key crew with each other (same movie)
              (mc1.job IN ($2, $3, $4, $5, $6, $7, $8, $9) AND mc2.job IN ($2, $3, $4, $5, $6, $7, $8, $9))
            )
        )
        SELECT 
          person_a_id,
          person_b_id,
          movie_id,
          collaboration_type,
          year,
          vote_average,
          revenue,
          release_date
        FROM person_pairs
        """

        # Pass movie_batch as first parameter, then all 8 key_crew_jobs
        params = [movie_batch] ++ key_crew_jobs
        results = Repo.query!(collaborations_query, params)

        # Group by person pairs
        pairs_map = Enum.group_by(results.rows, fn [p1, p2 | _] -> {p1, p2} end)

        batch_new_count =
          Enum.reduce(pairs_map, 0, fn {{person_a_id, person_b_id}, rows}, count ->
            # Check if collaboration already exists
            existing =
              Repo.get_by(Collaboration, person_a_id: person_a_id, person_b_id: person_b_id)

            collab_data =
              Enum.reduce(
                rows,
                %{
                  movie_ids: MapSet.new(),
                  release_dates: [],
                  ratings: [],
                  revenues: [],
                  years: MapSet.new(),
                  details: []
                },
                fn [_, _, movie_id, collab_type, year, rating, revenue, release_date], acc ->
                  %{
                    acc
                    | movie_ids: MapSet.put(acc.movie_ids, movie_id),
                      release_dates: [release_date | acc.release_dates],
                      ratings: if(rating, do: [rating | acc.ratings], else: acc.ratings),
                      revenues: if(revenue, do: [revenue | acc.revenues], else: acc.revenues),
                      years: if(year, do: MapSet.put(acc.years, year), else: acc.years),
                      details: [
                        %{
                          movie_id: movie_id,
                          collaboration_type: collab_type,
                          year: year,
                          movie_rating: rating,
                          movie_revenue: if(is_nil(revenue), do: 0, else: trunc(revenue))
                        }
                        | acc.details
                      ]
                  }
                end
              )

            if existing do
              # Update existing collaboration
              {:ok, collaboration} =
                existing
                |> Collaboration.changeset(%{
                  collaboration_count:
                    existing.collaboration_count + MapSet.size(collab_data.movie_ids),
                  first_collaboration_date:
                    Enum.min([existing.first_collaboration_date | collab_data.release_dates]),
                  latest_collaboration_date:
                    Enum.max([existing.latest_collaboration_date | collab_data.release_dates]),
                  avg_movie_rating:
                    if(length(collab_data.ratings) > 0,
                      do:
                        Decimal.from_float(
                          Enum.sum(collab_data.ratings) / length(collab_data.ratings)
                        ),
                      else: existing.avg_movie_rating
                    ),
                  total_revenue: existing.total_revenue + (Enum.sum(collab_data.revenues) || 0),
                  years_active:
                    Enum.sort(
                      Enum.uniq(existing.years_active ++ MapSet.to_list(collab_data.years))
                    )
                })
                |> Repo.update()

              # Add new details
              Enum.each(collab_data.details, fn detail ->
                %CollaborationDetail{}
                |> CollaborationDetail.changeset(
                  Map.put(detail, :collaboration_id, collaboration.id)
                )
                |> Repo.insert()
              end)

              count
            else
              # Insert new collaboration
              {:ok, collaboration} =
                %Collaboration{}
                |> Collaboration.changeset(%{
                  person_a_id: person_a_id,
                  person_b_id: person_b_id,
                  collaboration_count: MapSet.size(collab_data.movie_ids),
                  first_collaboration_date: Enum.min(collab_data.release_dates),
                  latest_collaboration_date: Enum.max(collab_data.release_dates),
                  avg_movie_rating:
                    if(length(collab_data.ratings) > 0,
                      do:
                        Decimal.from_float(
                          Enum.sum(collab_data.ratings) / length(collab_data.ratings)
                        ),
                      else: nil
                    ),
                  total_revenue: Enum.sum(collab_data.revenues) || 0,
                  years_active: Enum.sort(MapSet.to_list(collab_data.years))
                })
                |> Repo.insert()

              # Insert details
              Enum.each(collab_data.details, fn detail ->
                %CollaborationDetail{}
                |> CollaborationDetail.changeset(
                  Map.put(detail, :collaboration_id, collaboration.id)
                )
                |> Repo.insert()
              end)

              count + 1
            end
          end)

        acc_count + batch_new_count
      end)

    total_collaborations = Repo.aggregate(Collaboration, :count, :id)
    IO.puts("✓ Created #{total_collaborations} collaborations")

    {:ok, total_collaborations}
  end

  @doc """
  Refreshes the `person_collaboration_trends` materialized view.

  Delegates to the single safe refresh path
  (`Cinegraph.Database.MaterializedViews.refresh!/2`): CONCURRENTLY (non-blocking)
  plus a server-side `statement_timeout`. The scheduled
  `Cinegraph.Workers.MaterializedViewRefreshSweeper` is the normal driver; this is
  the on-demand entry point.
  """
  def refresh_collaboration_trends(opts \\ []) do
    Cinegraph.Database.MaterializedViews.refresh!("person_collaboration_trends", opts)
  end

  @doc """
  Finds movies where two people worked together.

  Accepts `:type` as `:any`, a collaboration type string, or a list of
  collaboration type strings.
  """
  def find_collaboration_movies(person_a_id, person_b_id, opts \\ []) do
    {person_a_id, person_b_id} = order_person_ids(person_a_id, person_b_id)
    types = collaboration_type_filter(Keyword.get(opts, :type, :any))

    query =
      from cd in CollaborationDetail,
        join: c in Collaboration,
        on: cd.collaboration_id == c.id,
        join: m in Movie,
        on: cd.movie_id == m.id,
        where: c.person_a_id == ^person_a_id and c.person_b_id == ^person_b_id,
        group_by: [m.id, m.title, m.slug, m.release_date, m.poster_path],
        order_by: [desc: m.release_date],
        select: %{
          id: m.id,
          title: m.title,
          slug: m.slug,
          release_date: m.release_date,
          poster_path: m.poster_path,
          score: max(cd.movie_rating)
        }

    query
    |> maybe_filter_collaboration_types(types)
    |> Repo.replica().all()
    |> Enum.map(&normalize_collaboration_movie/1)
  end

  @doc """
  Finds movies where a specific actor and director worked together.
  """
  def find_actor_director_movies(actor_id, director_id) do
    find_collaboration_movies(actor_id, director_id, type: "actor-director")
  end

  defp collaboration_type_filter(:any), do: :any
  defp collaboration_type_filter(""), do: :any
  defp collaboration_type_filter(type) when is_binary(type), do: [type]

  defp collaboration_type_filter(types) when is_list(types) do
    types
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp collaboration_type_filter(_), do: :any

  defp maybe_filter_collaboration_types(query, :any), do: query
  defp maybe_filter_collaboration_types(query, []), do: where(query, false)

  defp maybe_filter_collaboration_types(query, types),
    do: where(query, [cd], cd.collaboration_type in ^types)

  defp normalize_collaboration_movie(%{score: %Decimal{} = score} = movie),
    do: %{movie | score: Decimal.to_float(score)}

  defp normalize_collaboration_movie(movie), do: movie

  @doc """
  Finds similar collaborations based on genres and success metrics.
  """
  def find_similar_collaborations(actor_id, director_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    {person_a_id, person_b_id} = order_person_ids(actor_id, director_id)

    # Get the original collaboration's metrics
    original =
      Repo.replica().get_by(Collaboration, person_a_id: person_a_id, person_b_id: person_b_id)

    if original do
      query =
        from c in Collaboration,
          join: cd in CollaborationDetail,
          on: cd.collaboration_id == c.id,
          where: c.id != ^original.id,
          where: cd.collaboration_type == "actor-director",
          where: c.collaboration_count >= 2,
          group_by: c.id,
          order_by: [
            asc: fragment("ABS(? - ?)", c.avg_movie_rating, ^original.avg_movie_rating),
            desc: c.collaboration_count
          ],
          limit: ^limit,
          preload: [:person_a, :person_b]

      Repo.replica().all(query)
    else
      []
    end
  end

  @doc """
  Finds the shortest path between two people using PostgreSQL recursive CTE.
  """
  def find_shortest_path(from_person_id, to_person_id, max_depth \\ 6) do
    calculate_path(from_person_id, to_person_id, max_depth)
  end

  defp calculate_path(from_id, to_id, max_depth) do
    query = """
    WITH RECURSIVE path_search AS (
      -- Base case: direct connections through movies
      SELECT
        p1.id as from_person,
        p2.id as to_person,
        ARRAY[p1.id, p2.id] as path,
        1 as depth,
        mc1.movie_id as via_movie
      FROM people p1
      JOIN movie_credits mc1 ON p1.id = mc1.person_id
      JOIN movie_credits mc2 ON mc1.movie_id = mc2.movie_id
      JOIN people p2 ON mc2.person_id = p2.id
      WHERE p1.id = $1 AND p2.id != $1

      UNION ALL

      -- Recursive case
      SELECT
        ps.from_person,
        p2.id as to_person,
        ps.path || p2.id as path,
        ps.depth + 1 as depth,
        mc2.movie_id as via_movie
      FROM path_search ps
      JOIN movie_credits mc1 ON ps.to_person = mc1.person_id
      JOIN movie_credits mc2 ON mc1.movie_id = mc2.movie_id
      JOIN people p2 ON mc2.person_id = p2.id
      WHERE p2.id != ALL(ps.path)  -- Avoid cycles
        AND ps.depth < $3
        AND ps.to_person != $2  -- Stop if we already found target
    )
    SELECT DISTINCT ON (path)
      path,
      depth
    FROM path_search
    WHERE to_person = $2
    ORDER BY path, depth
    LIMIT 1
    """

    case Repo.replica().query(query, [from_id, to_id, max_depth]) do
      {:ok, %{rows: [[path, depth]]}} ->
        # Return a simple map with the path information
        {:ok,
         %{
           from_person_id: from_id,
           to_person_id: to_id,
           degree: depth,
           shortest_path: path
         }}

      {:ok, %{rows: []}} ->
        {:error, :no_path_found}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Gets collaboration trends for a person by year.
  Uses read replica for better load distribution.
  """
  def get_person_collaboration_trends(person_id) do
    query = """
    SELECT * FROM person_collaboration_trends
    WHERE person_id = $1
    ORDER BY year DESC
    """

    case Repo.replica().query(query, [person_id]) do
      {:ok, result} ->
        Enum.map(result.rows, fn row ->
          [
            _person_id,
            year,
            unique_collabs,
            new_collabs,
            total_collabs,
            avg_rating,
            total_revenue,
            genre_ids
          ] = row

          %{
            year: year,
            unique_collaborators: unique_collabs,
            new_collaborators: new_collabs,
            total_collaborations: total_collabs,
            avg_rating: avg_rating,
            total_revenue: total_revenue,
            genre_ids: genre_ids || []
          }
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Lists frequent collaborators for a person from the precomputed collaborations table.
  """
  def get_frequent_collaborators(%{id: person_id}), do: get_frequent_collaborators(person_id)

  def get_frequent_collaborators(person_id) when is_binary(person_id) do
    case Integer.parse(person_id) do
      {id, ""} -> get_frequent_collaborators(id)
      _ -> []
    end
  end

  def get_frequent_collaborators(person_id) when is_integer(person_id) do
    query =
      from c in Collaboration,
        join: p in Person,
        on:
          (c.person_a_id == ^person_id and p.id == c.person_b_id) or
            (c.person_b_id == ^person_id and p.id == c.person_a_id),
        where: c.collaboration_count >= 2,
        order_by: [desc: c.collaboration_count, desc: c.latest_collaboration_date],
        limit: 8,
        select: %{
          person: p,
          collaboration_count: c.collaboration_count,
          first_date: c.first_collaboration_date,
          latest_date: c.latest_collaboration_date,
          avg_rating: c.avg_movie_rating,
          total_revenue: c.total_revenue
        }

    query
    |> Repo.replica().all()
    |> Enum.map(fn summary ->
      Map.put(summary, :strength, collaboration_strength(summary.collaboration_count))
    end)
  end

  def get_frequent_collaborators(_), do: []

  defp collaboration_strength(count) when count >= 10, do: :very_strong
  defp collaboration_strength(count) when count >= 5, do: :strong
  defp collaboration_strength(_), do: :moderate

  @doc """
  Finds directors who frequently work with specific actors.
  """
  def find_director_frequent_actors(director_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    min_movies = Keyword.get(opts, :min_movies, 2)

    query =
      from c in Collaboration,
        join: cd in CollaborationDetail,
        on: cd.collaboration_id == c.id,
        join: p in Person,
        on:
          (c.person_a_id == ^director_id and p.id == c.person_b_id) or
            (c.person_b_id == ^director_id and p.id == c.person_a_id),
        where: cd.collaboration_type == "actor-director",
        where: c.collaboration_count >= ^min_movies,
        group_by: [c.id, p.id],
        order_by: [desc: c.collaboration_count, desc: c.avg_movie_rating],
        limit: ^limit,
        select: %{
          person: p,
          collaboration: c,
          movie_count: c.collaboration_count,
          avg_rating: c.avg_movie_rating,
          total_revenue: c.total_revenue,
          years_active: c.years_active
        }

    Repo.replica().all(query)
  end

  @doc """
  Detects trending collaborations in recent years.
  """
  def find_trending_collaborations(start_year, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    query =
      from c in Collaboration,
        join: cd in assoc(c, :details),
        where: cd.year >= ^start_year,
        group_by: c.id,
        having: count(cd.id) >= 2,
        order_by: [desc: sum(cd.movie_revenue), desc: avg(cd.movie_rating)],
        limit: ^limit,
        preload: [:person_a, :person_b]

    Repo.replica().all(query)
  end

  # Helper to ensure consistent person ordering
  defp order_person_ids(id1, id2) when id1 < id2, do: {id1, id2}
  defp order_person_ids(id1, id2), do: {id2, id1}
end
