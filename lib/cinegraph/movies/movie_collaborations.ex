defmodule Cinegraph.Movies.MovieCollaborations do
  @moduledoc """
  Business logic for finding and analyzing collaborations in movies.
  Extracted from LiveView to improve separation of concerns.
  """

  alias Cinegraph.Repo
  alias Cinegraph.Movies.{MovieScoring, Search}

  @movie_show_collaboration_policy %{
    included_types: [:actor_actor, :director_actor, :director_director],
    min_films_together: 2,
    limit: 6
  }

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
        movies = linked_movies(actor.person, director.person)

        if length(movies) >= @movie_show_collaboration_policy.min_films_together do
          %{
            type: :director_actor,
            display_category: :actor_director,
            roles_summary: "actor/director partnership",
            person_a: actor.person,
            person_b: director.person,
            collaboration_count: length(movies),
            films_together: length(movies),
            movies: movies,
            is_reunion: true
          }
        end
      end
      |> Enum.reject(&is_nil/1)

    # Actor-Actor partnerships
    actor_partnerships =
      for {actor1, idx} <- Enum.with_index(top_actors),
          actor2 <- Enum.slice(top_actors, (idx + 1)..-1//1) do
        movies = linked_movies(actor1.person, actor2.person)

        if length(movies) >= @movie_show_collaboration_policy.min_films_together do
          %{
            type: :actor_actor,
            display_category: :actor_pair,
            roles_summary: "acting partnership",
            person_a: actor1.person,
            person_b: actor2.person,
            collaboration_count: length(movies),
            films_together: length(movies),
            movies: movies,
            is_reunion: true
          }
        end
      end
      |> Enum.reject(&is_nil/1)

    director_director_reunions =
      for {director1, idx} <- Enum.with_index(directors),
          director2 <- Enum.slice(directors, (idx + 1)..-1//1) do
        movies = linked_movies(director1.person, director2.person)

        if length(movies) >= @movie_show_collaboration_policy.min_films_together do
          %{
            type: :director_director,
            display_category: :director_pair,
            roles_summary: "director partnership",
            person_a: director1.person,
            person_b: director2.person,
            collaboration_count: length(movies),
            films_together: length(movies),
            movies: movies,
            is_reunion: true
          }
        end
      end
      |> Enum.reject(&is_nil/1)

    # Combine and sort by collaboration count
    all_collaborations =
      (director_actor_reunions ++ actor_partnerships ++ director_director_reunions)
      |> Enum.filter(&(&1.type in @movie_show_collaboration_policy.included_types))
      |> Enum.sort_by(&collaboration_rank/1, :desc)
      |> Enum.take(@movie_show_collaboration_policy.limit)

    %{
      director_actor_reunions: Enum.filter(all_collaborations, &(&1.type == :director_actor)),
      actor_partnerships: Enum.filter(all_collaborations, &(&1.type == :actor_actor)),
      notable_collaborations: all_collaborations,
      total_reunions: length(all_collaborations)
    }
  end

  defp linked_movies(person_a, person_b) do
    people =
      [person_filter_value(person_a), person_filter_value(person_b)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(",")

    if people == "" do
      []
    else
      case Search.search_movies(%{
             "people" => people,
             "people_match" => "all",
             "per_page" => "50"
           }) do
        {:ok, {movies, _meta}} -> Enum.map(movies, &shape_timeline_movie/1)
        _ -> []
      end
    end
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
      score: MovieScoring.get_movie_score(movie.id)
    }
  end

  defp person_filter_value(%{slug: slug}) when is_binary(slug) and slug != "", do: slug
  defp person_filter_value(%{id: id}) when not is_nil(id), do: to_string(id)
  defp person_filter_value(_person), do: nil

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
