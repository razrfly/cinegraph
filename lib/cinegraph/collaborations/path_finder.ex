defmodule Cinegraph.Collaborations.PathFinder do
  @moduledoc """
  Optimized path finding for Six Degrees of Separation queries.
  Uses breadth-first search to find shortest paths between people.
  """

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Credit

  @doc """
  Finds the shortest path between two people using BFS.
  Returns {:ok, path} or {:error, :no_path_found}
  """
  def find_shortest_path(from_person_id, to_person_id, max_depth \\ 6) do
    calculate_path_bfs(from_person_id, to_person_id, max_depth)
  end

  defp calculate_path_bfs(from_id, to_id, max_depth) do
    # Use breadth-first search with a queue
    # Start with the source person
    queue = :queue.in({from_id, [from_id], 0}, :queue.new())
    visited = MapSet.new([from_id])

    result = bfs_loop(queue, visited, to_id, max_depth)

    case result do
      {:ok, path} ->
        {:ok, path}

      :not_found ->
        {:error, :no_path_found}
    end
  end

  defp bfs_loop(queue, visited, target_id, max_depth) do
    case :queue.out(queue) do
      {{:value, {current_id, path, depth}}, rest_queue} ->
        if current_id == target_id do
          {:ok, path}
        else
          if depth < max_depth do
            # Get all people connected to current person through movies
            connected = get_connected_people(current_id)

            # Process unvisited connections
            {new_queue, new_visited} =
              Enum.reduce(connected, {rest_queue, visited}, fn person_id, {q, v} ->
                if MapSet.member?(v, person_id) do
                  {q, v}
                else
                  new_path = path ++ [person_id]

                  {
                    :queue.in({person_id, new_path, depth + 1}, q),
                    MapSet.put(v, person_id)
                  }
                end
              end)

            bfs_loop(new_queue, new_visited, target_id, max_depth)
          else
            bfs_loop(rest_queue, visited, target_id, max_depth)
          end
        end

      {:empty, _} ->
        :not_found
    end
  end

  defp get_connected_people(person_id) do
    # Get all people who worked on same movies
    # This is more efficient than the recursive CTE
    query =
      from mc1 in Credit,
        join: mc2 in Credit,
        on: mc1.movie_id == mc2.movie_id,
        where: mc1.person_id == ^person_id,
        where: mc2.person_id != ^person_id,
        select: mc2.person_id,
        distinct: true

    Repo.all(query)
  end


  @doc """
  Finds a path with movie connections for display.
  Returns a list of {person, movie, person} tuples showing the connection path.
  """
  def find_path_with_movies(from_person_id, to_person_id) do
    case find_shortest_path(from_person_id, to_person_id) do
      {:ok, path} when length(path) > 1 ->
        # For each pair of people in the path, find the movie that connects them
        connections =
          path
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.map(fn [person_a_id, person_b_id] ->
            movie = find_connecting_movie(person_a_id, person_b_id)
            {person_a_id, movie, person_b_id}
          end)

        {:ok, connections}

      {:ok, _} ->
        # Same person
        {:ok, []}

      error ->
        error
    end
  end

  defp find_connecting_movie(person_a_id, person_b_id) do
    Repo.one(
      from m in "movies",
        join: mc1 in Credit,
        on: mc1.movie_id == m.id,
        join: mc2 in Credit,
        on: mc2.movie_id == m.id,
        where: mc1.person_id == ^person_a_id,
        where: mc2.person_id == ^person_b_id,
        select: %{
          id: m.id,
          title: m.title,
          year: fragment("EXTRACT(YEAR FROM ?)", m.release_date)
        },
        limit: 1
    )
  end

end
