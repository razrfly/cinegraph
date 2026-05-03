defmodule Cinegraph.Health.ImdbListIntegrityAudit do
  @moduledoc """
  DB-only integrity diagnostics for IMDb-backed canonical movie lists.

  This audit does not fetch IMDb or mutate data. It inspects the stored
  `movies.canonical_sources` memberships for active IMDb `movie_lists`.
  """

  import Ecto.Query

  alias Cinegraph.Movies.{Movie, MovieList}
  alias Cinegraph.Repo

  @first_missing_limit 20

  @doc """
  Return a JSON-safe audit of stored IMDb list membership integrity.
  """
  def audit(_opts \\ []) do
    movie_lists =
      MovieList
      |> where([ml], ml.active == true and ml.source_type == "imdb")
      |> order_by([ml], asc: ml.source_key)
      |> Repo.replica().all()

    memberships_by_source_key =
      movie_lists
      |> Enum.map(& &1.source_key)
      |> memberships_by_source_key()

    lists =
      Enum.map(movie_lists, fn list ->
        decorate_list(list, Map.get(memberships_by_source_key, list.source_key, []))
      end)

    %{
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      summary: summary(lists),
      lists: lists,
      recommended_commands: recommended_commands(lists)
    }
  end

  defp decorate_list(%MovieList{} = list, memberships) do
    positions = Enum.flat_map(memberships, &position_values/1)
    expected = expected_movie_count(list.metadata || %{})
    stored_count = length(memberships)
    ranked_count = length(positions)
    frequencies = Enum.frequencies(positions)
    duplicate_positions = duplicate_positions(frequencies)
    unique_positions = positions |> MapSet.new() |> MapSet.to_list() |> Enum.sort()
    min_position = Enum.min(unique_positions, fn -> nil end)
    max_position = Enum.max(unique_positions, fn -> nil end)
    missing_positions = missing_positions(unique_positions, max_position)
    gap_ranges = ranges(missing_positions)
    unranked_count = stored_count - length(positions)

    row = %{
      source_key: list.source_key,
      name: list.name,
      source_url: list.source_url,
      source_id: list.source_id,
      expected_movie_count: expected,
      stored_movie_count: stored_count,
      ranked_movie_count: ranked_count,
      min_position: min_position,
      max_position: max_position,
      distinct_positions: length(unique_positions),
      missing_position_count: length(missing_positions),
      first_missing_positions: Enum.take(missing_positions, @first_missing_limit),
      position_gap_ranges: gap_ranges,
      duplicate_positions: duplicate_positions,
      unranked_count: unranked_count
    }

    Map.put(row, :status, status(row))
  end

  defp memberships_by_source_key([]), do: %{}

  defp memberships_by_source_key(source_keys) do
    Movie
    |> where(
      [m],
      fragment("? \\?| ?", m.canonical_sources, type(^source_keys, {:array, :string}))
    )
    |> select([m], m.canonical_sources)
    |> Repo.replica().all()
    |> Enum.reduce(%{}, fn canonical_sources, acc ->
      Enum.reduce(source_keys, acc, fn source_key, acc ->
        case Map.get(canonical_sources || %{}, source_key) do
          nil -> acc
          metadata -> Map.update(acc, source_key, [metadata], &[metadata | &1])
        end
      end)
    end)
    |> Map.new(fn {source_key, memberships} -> {source_key, Enum.reverse(memberships)} end)
  end

  defp position_values(metadata) when is_map(metadata) do
    case Map.get(metadata, "list_position") || Map.get(metadata, :list_position) do
      n when is_integer(n) and n > 0 -> [n]
      n when is_binary(n) -> parse_position(n)
      _ -> []
    end
  end

  defp position_values(_metadata), do: []

  defp parse_position(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> [n]
      _ -> []
    end
  end

  defp missing_positions(_positions, nil), do: []

  defp missing_positions(positions, max_position) do
    present = MapSet.new(positions)

    1..max_position
    |> Enum.reject(&MapSet.member?(present, &1))
  end

  defp duplicate_positions(frequencies) do
    frequencies
    |> Enum.filter(fn {_position, count} -> count > 1 end)
    |> Enum.map(fn {position, count} -> %{position: position, count: count} end)
    |> Enum.sort_by(& &1.position)
  end

  defp ranges([]), do: []

  defp ranges([first | rest]) do
    {ranges, start, last} =
      Enum.reduce(rest, {[], first, first}, fn position, {acc, start, last} ->
        if position == last + 1 do
          {acc, start, position}
        else
          {[%{from: start, to: last} | acc], position, position}
        end
      end)

    Enum.reverse([%{from: start, to: last} | ranges])
  end

  defp status(%{stored_movie_count: 0}), do: "blank"

  defp status(%{missing_position_count: missing, duplicate_positions: duplicates})
       when missing > 0 or duplicates != [],
       do: "discontinuous"

  defp status(%{expected_movie_count: expected, ranked_movie_count: ranked})
       when is_integer(expected) and ranked < expected,
       do: "partial"

  defp status(%{expected_movie_count: expected}) when is_integer(expected), do: "complete"
  defp status(_row), do: "missing_expected_count"

  defp expected_movie_count(%{} = metadata) do
    case metadata["expected_movie_count"] do
      n when is_integer(n) and n > 0 -> n
      n when is_binary(n) -> parse_positive_integer(n)
      _ -> nil
    end
  end

  defp parse_positive_integer(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp summary(lists) do
    %{
      total_active_imdb: length(lists),
      complete: count_status(lists, "complete"),
      partial: count_status(lists, "partial"),
      discontinuous: count_status(lists, "discontinuous"),
      blank: count_status(lists, "blank"),
      missing_expected_count: count_status(lists, "missing_expected_count")
    }
  end

  defp count_status(lists, status), do: Enum.count(lists, &(&1.status == status))

  defp recommended_commands(lists) do
    lists
    |> Enum.reject(&(&1.status == "complete"))
    |> Enum.map(fn list ->
      starts = recommended_starts(list)
      starts_arg = if starts == [], do: "", else: " --starts #{Enum.join(starts, ",")}"

      "mix cinegraph.prod.audit.imdb_list_pagination --list #{list.source_key}#{starts_arg} --json"
    end)
  end

  defp recommended_starts(%{first_missing_positions: positions}) when positions != [] do
    positions
    |> Enum.map(&window_start/1)
    |> Enum.uniq()
  end

  defp recommended_starts(_list), do: []

  defp window_start(position) do
    div(position - 1, 75) * 75 + 1
  end
end
