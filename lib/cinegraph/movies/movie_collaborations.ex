defmodule Cinegraph.Movies.MovieCollaborations do
  @moduledoc """
  Business logic for finding and analyzing collaborations in movies.
  Extracted from LiveView to improve separation of concerns.
  """

  import Ecto.Query, warn: false

  alias Cinegraph.Repo
  alias Cinegraph.Movies.MovieScoring

  @movie_show_collaboration_policy %{
    included_types: [:actor_actor, :director_actor, :director_director],
    min_films_together: 2,
    limit: 6
  }

  @doc """
  Get key collaborations (director-actor reunions and actor partnerships) for a movie.
  """
  def get_key_collaborations(cast, crew) do
    directors = Enum.filter(crew, &(&1.job == "Director"))
    top_actors = Enum.take(cast, 10)

    director_person_ids =
      directors |> Enum.map(& &1.person) |> Enum.map(&person_id/1) |> Enum.reject(&is_nil/1)

    actor_person_ids =
      top_actors |> Enum.map(& &1.person) |> Enum.map(&person_id/1) |> Enum.reject(&is_nil/1)

    all_person_ids = Enum.uniq(director_person_ids ++ actor_person_ids)

    if length(all_person_ids) < 2 do
      empty_collaborations()
    else
      movies_batch = batch_linked_movies(all_person_ids)

      director_actor_reunions =
        for director <- directors,
            actor <- top_actors,
            director_id = person_id(director.person),
            actor_id = person_id(actor.person),
            not is_nil(director_id),
            not is_nil(actor_id) do
          shared =
            movies_batch
            |> Enum.filter(fn m ->
              director_id in (m.director_ids || []) and actor_id in (m.actor_ids || [])
            end)
            |> Enum.map(&shape_timeline_movie/1)

          if length(shared) >= @movie_show_collaboration_policy.min_films_together do
            %{
              type: :director_actor,
              display_category: :actor_director,
              roles_summary: "actor/director partnership",
              person_a: actor.person,
              person_b: director.person,
              collaboration_count: length(shared),
              films_together: length(shared),
              movies: shared,
              is_reunion: true
            }
          end
        end
        |> Enum.reject(&is_nil/1)

      actor_partnerships =
        for {actor1, idx} <- Enum.with_index(top_actors),
            actor2 <- Enum.drop(top_actors, idx + 1),
            id1 = person_id(actor1.person),
            id2 = person_id(actor2.person),
            not is_nil(id1),
            not is_nil(id2) do
          shared =
            movies_batch
            |> Enum.filter(fn m ->
              id1 in (m.actor_ids || []) and id2 in (m.actor_ids || [])
            end)
            |> Enum.map(&shape_timeline_movie/1)

          if length(shared) >= @movie_show_collaboration_policy.min_films_together do
            %{
              type: :actor_actor,
              display_category: :actor_pair,
              roles_summary: "acting partnership",
              person_a: actor1.person,
              person_b: actor2.person,
              collaboration_count: length(shared),
              films_together: length(shared),
              movies: shared,
              is_reunion: true
            }
          end
        end
        |> Enum.reject(&is_nil/1)

      director_director_reunions =
        for {director1, idx} <- Enum.with_index(directors),
            director2 <- Enum.drop(directors, idx + 1),
            id1 = person_id(director1.person),
            id2 = person_id(director2.person),
            not is_nil(id1),
            not is_nil(id2) do
          shared =
            movies_batch
            |> Enum.filter(fn m ->
              id1 in (m.director_ids || []) and id2 in (m.director_ids || [])
            end)
            |> Enum.map(&shape_timeline_movie/1)

          if length(shared) >= @movie_show_collaboration_policy.min_films_together do
            %{
              type: :director_director,
              display_category: :director_pair,
              roles_summary: "director partnership",
              person_a: director1.person,
              person_b: director2.person,
              collaboration_count: length(shared),
              films_together: length(shared),
              movies: shared,
              is_reunion: true
            }
          end
        end
        |> Enum.reject(&is_nil/1)

      full_collaborations =
        (director_actor_reunions ++ actor_partnerships ++ director_director_reunions)
        |> Enum.filter(&(&1.type in @movie_show_collaboration_policy.included_types))

      all_collaborations =
        full_collaborations
        |> hydrate_collaboration_scores()
        |> Enum.sort_by(&collaboration_rank/1, :desc)
        |> Enum.take(@movie_show_collaboration_policy.limit)

      %{
        director_actor_reunions: Enum.filter(all_collaborations, &(&1.type == :director_actor)),
        actor_partnerships: Enum.filter(all_collaborations, &(&1.type == :actor_actor)),
        director_director_reunions:
          Enum.filter(all_collaborations, &(&1.type == :director_director)),
        notable_collaborations: all_collaborations,
        total_reunions: length(full_collaborations)
      }
    end
  end

  defp batch_linked_movies(person_ids) do
    query = """
    SELECT
      m.id, m.title, m.slug, m.poster_path, m.release_date,
      ARRAY_AGG(DISTINCT mc.person_id) FILTER (WHERE mc.credit_type = 'cast') as actor_ids,
      ARRAY_AGG(DISTINCT mc.person_id) FILTER (WHERE mc.credit_type = 'crew' AND mc.job = 'Director') as director_ids
    FROM movies m
    JOIN movie_credits mc ON mc.movie_id = m.id
    WHERE mc.person_id = ANY($1::int[])
      AND m.import_status = 'full'
      AND (m.release_date IS NULL OR m.release_date <= $2)
    GROUP BY m.id, m.title, m.slug, m.poster_path, m.release_date
    HAVING COUNT(DISTINCT mc.person_id) >= 2
    ORDER BY m.release_date DESC
    """

    case Repo.replica().query(query, [person_ids, Date.utc_today()]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [id, title, slug, poster_path, release_date, actor_ids, director_ids] ->
          %{
            id: id,
            title: title,
            slug: slug,
            poster_path: poster_path,
            release_date: release_date,
            actor_ids: actor_ids || [],
            director_ids: director_ids || []
          }
        end)

      _ ->
        []
    end
  end

  defp empty_collaborations do
    %{
      director_actor_reunions: [],
      actor_partnerships: [],
      director_director_reunions: [],
      notable_collaborations: [],
      total_reunions: 0
    }
  end

  defp collaboration_rank(collaboration) do
    type_rank =
      case collaboration.type do
        :actor_actor -> 3
        :director_actor -> 2
        :director_director -> 1
        _ -> 0
      end

    {length(collaboration.movies || []), type_rank}
  end

  defp shape_timeline_movie(movie) do
    %{
      id: movie.id,
      title: movie.title,
      slug: movie.slug,
      release_date: movie.release_date,
      poster_path: Map.get(movie, :poster_path),
      score: nil
    }
  end

  defp hydrate_collaboration_scores(collaborations) do
    scores =
      collaborations
      |> Enum.flat_map(&(&1.movies || []))
      |> Enum.map(& &1.id)
      |> MovieScoring.get_movie_scores()

    Enum.map(collaborations, fn collaboration ->
      movies =
        Enum.map(collaboration.movies || [], fn movie ->
          %{movie | score: Map.get(scores, movie.id)}
        end)

      %{collaboration | movies: movies}
    end)
  end

  defp person_id(%{id: id}) when is_integer(id), do: id
  defp person_id(_person), do: nil

  @doc """
  Get collaboration timelines for key partnerships in a movie.
  """
  def get_collaboration_timelines(_movie, key_collaborations) do
    # Build timelines per key collaboration
    timelines =
      for collab <- key_collaborations[:notable_collaborations] || [] do
        %{
          type: collab.type,
          person_a: collab.person_a,
          person_b: collab.person_b,
          movies: collab.movies,
          collaboration_strength: MovieScoring.calculate_collaboration_strength(collab.movies)
        }
      end

    timelines
  end

  @doc """
  Find related movies based on shared cast and crew.
  """
  def get_related_movies_by_collaboration(movie, cast, crew) do
    # Get top cast and crew IDs
    person_ids =
      (Enum.take(cast, 5) ++ Enum.filter(crew, &(&1.job in ["Director", "Writer", "Producer"])))
      |> Enum.take(3)
      |> Enum.map(& &1.person_id)
      |> Enum.uniq()

    if length(person_ids) == 0 do
      []
    else
      # Find movies with shared cast/crew
      query = """
      WITH shared_people AS (
        SELECT 
          mc.movie_id,
          COUNT(DISTINCT mc.person_id) as shared_count,
          array_agg(DISTINCT p.name) as shared_names
        FROM movie_credits mc
        JOIN people p ON p.id = mc.person_id
        WHERE mc.person_id = ANY($1::int[])
          AND mc.movie_id != $2
        GROUP BY mc.movie_id
        HAVING COUNT(DISTINCT mc.person_id) >= 2
      )
      SELECT 
        m.id, m.title, m.release_date, m.poster_path, m.slug,
        sp.shared_count, sp.shared_names
      FROM movies m
      JOIN shared_people sp ON sp.movie_id = m.id
      WHERE m.import_status = 'full'
      ORDER BY sp.shared_count DESC, m.release_date DESC
      LIMIT 8
      """

      case Repo.replica().query(query, [person_ids, movie.id]) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [
                              id,
                              title,
                              release_date,
                              poster_path,
                              slug,
                              shared_count,
                              shared_names
                            ] ->
            %{
              id: id,
              title: title,
              release_date: release_date,
              poster_path: poster_path,
              slug: slug,
              shared_count: shared_count,
              shared_names: shared_names,
              connection_reason: format_connection_reason(shared_count, shared_names)
            }
          end)

        _ ->
          []
      end
    end
  end

  defp format_connection_reason(count, names) do
    case count do
      1 -> "Shares #{Enum.at(names, 0)}"
      2 -> "Shares #{Enum.join(names, " & ")}"
      _ -> "Shares #{count} cast/crew members"
    end
  end
end
