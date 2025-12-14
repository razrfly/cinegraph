defmodule Cinegraph.Collaborations do
  @moduledoc """
  The Collaborations context handles actor-director and other collaboration relationships.
  """

  import Ecto.Query, warn: false
  require Logger
  alias Cinegraph.Repo
  alias Cinegraph.Collaborations.{Collaboration, CollaborationDetail}
  alias Cinegraph.Movies.{Movie, Person}

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
  def populate_movie_collaborations(movie_id) do
    Repo.transaction(fn ->
      # Define key crew roles we care about
      key_crew_jobs = [
        "Director",
        "Producer",
        "Executive Producer",
        "Screenplay",
        "Writer",
        "Director of Photography",
        "Original Music Composer",
        "Editor"
      ]

      # Find all unique person pairs who worked together on this movie
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
          AND m.id = $1
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

      params = [movie_id | key_crew_jobs]

      case Repo.query(collaborations_query, params) do
        {:ok, %{rows: rows}} ->
          count =
            Enum.reduce(rows, 0, fn row, acc ->
              try do
                [
                  person_a_id,
                  person_b_id,
                  movie_id,
                  collaboration_type,
                  year,
                  vote_average,
                  revenue,
                  release_date
                ] = row

                # Update or create collaboration
                existing_collab =
                  Repo.get_by(Collaboration,
                    person_a_id: person_a_id,
                    person_b_id: person_b_id
                  )

                collaboration =
                  if existing_collab do
                    # Update existing collaboration
                    years = Enum.uniq([year | existing_collab.years_active || []])
                    revenue_value = if is_nil(revenue), do: 0, else: trunc(revenue)
                    total_revenue = (existing_collab.total_revenue || 0) + revenue_value

                    updated_attrs = %{
                      collaboration_count: existing_collab.collaboration_count + 1,
                      latest_collaboration_date:
                        max_date(existing_collab.latest_collaboration_date, release_date),
                      avg_movie_rating:
                        update_average(
                          existing_collab.avg_movie_rating,
                          existing_collab.collaboration_count,
                          vote_average
                        ),
                      total_revenue: total_revenue,
                      years_active: years
                    }

                    {:ok, updated} =
                      existing_collab
                      |> Collaboration.changeset(updated_attrs)
                      |> Repo.update()

                    updated
                  else
                    # Create new collaboration
                    revenue_value = if is_nil(revenue), do: 0, else: trunc(revenue)

                    attrs = %{
                      person_a_id: person_a_id,
                      person_b_id: person_b_id,
                      collaboration_count: 1,
                      first_collaboration_date: release_date,
                      latest_collaboration_date: release_date,
                      avg_movie_rating: vote_average,
                      total_revenue: revenue_value,
                      years_active: [year]
                    }

                    case %Collaboration{}
                         |> Collaboration.changeset(attrs)
                         |> Repo.insert() do
                      {:ok, new_collab} ->
                        new_collab

                      {:error,
                       %Ecto.Changeset{errors: [person_a_id: {"has already been taken", _}]}} ->
                        # Race condition: collaboration was created by another process
                        # Retry by fetching the existing collaboration
                        case Repo.get_by(Collaboration,
                               person_a_id: person_a_id,
                               person_b_id: person_b_id
                             ) do
                          nil ->
                            # Very rare case: the collaboration was deleted between the error and retry
                            Logger.warning(
                              "Collaboration not found after race condition for persons #{person_a_id} and #{person_b_id}"
                            )

                            nil

                          existing ->
                            existing
                        end

                      {:error, changeset} ->
                        # Re-raise other types of errors
                        raise "Failed to insert collaboration: #{inspect(changeset.errors)}"
                    end
                  end

                # Create collaboration detail only if we have a valid collaboration
                if collaboration do
                  revenue_value = if is_nil(revenue), do: 0, else: trunc(revenue)

                  detail_attrs = %{
                    collaboration_id: collaboration.id,
                    movie_id: movie_id,
                    year: year,
                    collaboration_type: collaboration_type,
                    movie_rating: vote_average,
                    movie_revenue: revenue_value
                  }

                  %CollaborationDetail{}
                  |> CollaborationDetail.changeset(detail_attrs)
                  |> Repo.insert(on_conflict: :nothing)

                  acc + 1
                else
                  # Skip this collaboration if we couldn't create/find it
                  Logger.warning(
                    "Skipping collaboration detail for movie #{movie_id} - collaboration not found"
                  )

                  acc
                end
              rescue
                error ->
                  Logger.error(
                    "Error processing collaboration for movie #{movie_id}: #{inspect(error)}"
                  )

                  # Continue processing other collaborations
                  acc
              end
            end)

          count

        {:error, error} ->
          Repo.rollback({:query_error, error})
      end
    end)
  end

  defp max_date(nil, date), do: date
  defp max_date(date, nil), do: date
  defp max_date(date1, date2) when date1 > date2, do: date1
  defp max_date(_date1, date2), do: date2

  defp update_average(nil, _count, new_value), do: new_value
  defp update_average(_old_avg, _count, nil), do: nil

  defp update_average(old_avg, count, new_value) do
    # Convert to float for arithmetic operations
    old_avg_float = if is_struct(old_avg, Decimal), do: Decimal.to_float(old_avg), else: old_avg

    new_value_float =
      if is_struct(new_value, Decimal), do: Decimal.to_float(new_value), else: new_value

    (old_avg_float * count + new_value_float) / (count + 1)
  end

  @doc """
  Populates only key collaborations: top 20 cast + directors + key crew.
  This prevents exponential explosion from movies with 1000+ credits.

  Accepts optional movie_ids list. If not provided, fetches all movie IDs from replica.
  """
  def populate_key_collaborations_only(movie_ids \\ nil) do
    IO.puts("Populating key collaborations (top 20 cast + directors + key crew)...")

    # Define key crew roles we care about
    key_crew_jobs = [
      "Director",
      "Producer",
      "Executive Producer",
      "Screenplay",
      "Writer",
      "Director of Photography",
      "Original Music Composer",
      "Editor"
    ]

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
  Refreshes the materialized view for collaboration trends.
  """
  def refresh_collaboration_trends do
    # TODO: Uncomment when materialized view is created
    # Repo.query!("REFRESH MATERIALIZED VIEW CONCURRENTLY person_collaboration_trends")
    :ok
  end

  @doc """
  Finds movies where a specific actor and director worked together.
  """
  def find_actor_director_movies(actor_id, director_id) do
    {person_a_id, person_b_id} = order_person_ids(actor_id, director_id)

    query =
      from cd in CollaborationDetail,
        join: c in Collaboration,
        on: cd.collaboration_id == c.id,
        join: m in Movie,
        on: cd.movie_id == m.id,
        where: c.person_a_id == ^person_a_id and c.person_b_id == ^person_b_id,
        where: cd.collaboration_type == "actor-director",
        order_by: [desc: m.release_date],
        preload: [movie: m]

    Repo.replica().all(query) |> Enum.map(& &1.movie)
  end

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
        join: cd in CollaborationDetail,
        on: cd.collaboration_id == c.id,
        where: cd.year >= ^start_year,
        where: c.first_collaboration_date >= ^Date.new!(start_year, 1, 1),
        group_by: c.id,
        having: count(cd.id) >= 2,
        order_by: [desc: avg(cd.movie_revenue), desc: avg(cd.movie_rating)],
        limit: ^limit,
        preload: [:person_a, :person_b]

    Repo.replica().all(query)
  end

  # Helper to ensure consistent person ordering
  defp order_person_ids(id1, id2) when id1 < id2, do: {id1, id2}
  defp order_person_ids(id1, id2), do: {id2, id1}
end
