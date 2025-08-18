defmodule Cinegraph.Movies.MovieCollaborations do
  @moduledoc """
  Business logic for finding and analyzing collaborations in movies.
  Extracted from LiveView to improve separation of concerns.
  """

  alias Cinegraph.Repo
  alias Cinegraph.Collaborations
  alias Cinegraph.Movies.MovieScoring

  @doc """
  Get key collaborations (director-actor reunions and actor partnerships) for a movie.
  """
  def get_key_collaborations(cast, crew) do
    # Get directors
    directors = Enum.filter(crew, &(&1.job == "Director"))

    # Get top actors
    top_actors = Enum.take(cast, 10)

    # Director-Actor reunions
    director_actor_reunions =
      for director <- directors,
          actor <- top_actors do
        case Collaborations.find_actor_director_movies(actor.person_id, director.person_id) do
          movies when length(movies) > 1 ->
            %{
              type: :director_actor,
              person_a: actor.person,
              person_b: director.person,
              collaboration_count: length(movies),
              is_reunion: true
            }

          _ ->
            nil
        end
      end
      |> Enum.reject(&is_nil/1)

    # Actor-Actor partnerships
    actor_partnerships =
      for {actor1, idx} <- Enum.with_index(top_actors),
          actor2 <- Enum.slice(top_actors, (idx + 1)..-1//1) do
        query = """
        SELECT c.collaboration_count
        FROM collaborations c
        WHERE (c.person_a_id = $1 AND c.person_b_id = $2)
           OR (c.person_a_id = $2 AND c.person_b_id = $1)
        """

        case Repo.query(query, [actor1.person_id, actor2.person_id]) do
          {:ok, %{rows: [[count]]}} when count > 1 ->
            %{
              type: :actor_actor,
              person_a: actor1.person,
              person_b: actor2.person,
              collaboration_count: count,
              is_reunion: true
            }

          _ ->
            nil
        end
      end
      |> Enum.reject(&is_nil/1)

    # Combine and sort by collaboration count
    all_collaborations =
      (director_actor_reunions ++ actor_partnerships)
      |> Enum.sort_by(& &1.collaboration_count, :desc)
      |> Enum.take(6)

    %{
      director_actor_reunions: Enum.filter(all_collaborations, &(&1.type == :director_actor)),
      actor_partnerships: Enum.filter(all_collaborations, &(&1.type == :actor_actor)),
      total_reunions: length(all_collaborations)
    }
  end

  @doc """
  Get collaboration timelines for key partnerships in a movie.
  """
  def get_collaboration_timelines(_movie, key_collaborations) do
    # Build timelines per key collaboration
    timelines =
      for collab <- key_collaborations.director_actor_reunions do
        movies =
          Collaborations.find_actor_director_movies(
            collab.person_a.id,
            collab.person_b.id
          )

        timeline_movies =
          Enum.map(movies, fn m ->
            # Get score for each movie
            avg_score = MovieScoring.get_movie_score(m.id)

            # Return a lightweight map (avoid mutating Ecto struct)
            %{
              id: m.id,
              title: m.title,
              slug: m.slug,
              release_date: m.release_date,
              score: avg_score
            }
          end)

        %{
          type: :director_actor,
          person_a: collab.person_a,
          person_b: collab.person_b,
          movies: timeline_movies,
          collaboration_strength: MovieScoring.calculate_collaboration_strength(timeline_movies)
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

      case Repo.query(query, [person_ids, movie.id]) do
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
