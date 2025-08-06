defmodule Cinegraph.Collaborations.PathFinder do
  @moduledoc """
  Optimized path finding for Six Degrees of Separation queries.
  Uses breadth-first search to find shortest paths between people.
  """

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Movies.{Person, Credit}
  alias Cinegraph.Collaborations.PersonRelationship

  @doc """
  Finds the shortest path between two people using BFS.
  Returns {:ok, path} or {:error, :no_path_found}
  """
  def find_shortest_path(from_person_id, to_person_id, max_depth \\ 6) do
    # First check cache
    case get_cached_path(from_person_id, to_person_id) do
      {:ok, path} -> {:ok, path}
      :not_found -> calculate_path_bfs(from_person_id, to_person_id, max_depth)
    end
  end

  defp get_cached_path(from_id, to_id) do
    now = DateTime.utc_now()

    case Repo.one(
           from pr in PersonRelationship,
             where: pr.from_person_id == ^from_id and pr.to_person_id == ^to_id,
             where: pr.expires_at > ^now,
             select: pr.shortest_path
         ) do
      nil -> :not_found
      path -> {:ok, path}
    end
  end

  defp calculate_path_bfs(from_id, to_id, max_depth) do
    # Use breadth-first search with a queue
    # Start with the source person
    queue = :queue.in({from_id, [from_id], 0}, :queue.new())
    visited = MapSet.new([from_id])

    result = bfs_loop(queue, visited, to_id, max_depth)

    case result do
      {:ok, path} ->
        # Cache the result
        cache_path(from_id, to_id, path)
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

  defp cache_path(from_id, to_id, path) do
    attrs = %{
      from_person_id: from_id,
      to_person_id: to_id,
      degree: length(path) - 1,
      shortest_path: path,
      calculated_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), 7, :day)
    }

    %PersonRelationship{}
    |> PersonRelationship.changeset(attrs)
    |> Repo.insert(on_conflict: :replace_all, conflict_target: [:from_person_id, :to_person_id])
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

  @doc """
  Pre-calculates paths for popular people to improve performance.
  """
  def precalculate_popular_paths(limit \\ 100) do
    # Get most popular/credited people
    popular_people =
      Repo.all(
        from p in Person,
          join: mc in Credit,
          on: mc.person_id == p.id,
          group_by: p.id,
          order_by: [desc: count(mc.id)],
          limit: ^limit,
          select: p.id
      )

    total = length(popular_people) * (length(popular_people) - 1)

    # Calculate paths between all pairs
    popular_people
    |> Enum.flat_map(fn from_id ->
      Enum.map(popular_people, &{from_id, &1})
    end)
    |> Enum.reject(fn {a, b} -> a == b end)
    |> Enum.with_index(1)
    |> Enum.each(fn {{from_id, to_id}, idx} ->
      find_shortest_path(from_id, to_id)
      if rem(idx, 100) == 0, do: IO.puts("Calculated #{idx}/#{total} paths...")
    end)

    IO.puts("✓ Pre-calculated #{total} paths")
  end
end
