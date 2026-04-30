defmodule Cinegraph.Search do
  @moduledoc """
  Unified typeahead search across films, people, lists, and companies.

  Single entry point: `global/2`. Fans out four parallel queries via
  `Task.async_stream/3` (100 ms hard timeout per group), caches the
  assembled result for 60s in `:movies_cache`, and emits `:telemetry`
  events at both the global and per-group level.

  Returns shaped maps designed to feed both the LiveView typeahead
  and the GraphQL `globalSearch` resolver.
  """

  import Ecto.Query
  require Logger

  alias Cinegraph.Repo
  alias Cinegraph.Movies.{Credit, Movie, MovieList, Person, ProductionCompany}

  @cache_ttl :timer.seconds(60)
  @group_timeout_ms 100
  @default_limit 5
  @min_query_length 2
  @max_limit 25

  @groups [:films, :people, :lists, :companies]

  @type group :: :films | :people | :lists | :companies
  @type result :: %{
          films: [map()],
          people: [map()],
          lists: [map()],
          companies: [map()],
          total_count: non_neg_integer()
        }

  @doc """
  Run a global typeahead search.

  ## Options

  * `:limit` — max rows per group (default #{@default_limit}, capped at #{@max_limit})

  Queries shorter than #{@min_query_length} characters short-circuit
  to an empty result without touching the cache or the database.
  """
  @spec global(String.t() | nil, keyword()) :: result()
  def global(raw_query, opts \\ []) do
    started = System.monotonic_time()
    query = normalize_query(raw_query)
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit) |> max(1)

    {value, cache_hit?} =
      if String.length(query) < @min_query_length do
        {empty_result(), false}
      else
        cached_compute(query, limit)
      end

    emit_global(started, query, cache_hit?)
    value
  end

  # ============================================================================
  # Cache wrap (kept inline so we know cache_hit? for telemetry)
  # ============================================================================

  defp cached_compute(query, limit) do
    key = cache_key(query, limit)

    case Cachex.get(:movies_cache, key) do
      {:ok, nil} ->
        {value, complete?} = compute(query, limit)
        # Don't cache partial results — a slow group should get retried, not
        # locked in for 60s as an empty list.
        if complete?, do: Cachex.put(:movies_cache, key, value, ttl: @cache_ttl)
        {value, false}

      {:ok, cached} ->
        {cached, true}

      {:error, reason} ->
        Logger.warning("[Cinegraph.Search] Cache error for #{key}: #{inspect(reason)}")
        {value, _} = compute(query, limit)
        {value, false}
    end
  end

  defp cache_key(query, limit), do: "search:global:#{query}:#{limit}"

  # ============================================================================
  # Parallel fan-out
  # ============================================================================

  defp compute(query, limit) do
    runners = [
      films: fn -> films(query, limit) end,
      people: fn -> people(query, limit) end,
      lists: fn -> lists(query, limit) end,
      companies: fn -> companies(query, limit) end
    ]

    stream =
      Task.async_stream(
        runners,
        fn {group, fun} -> {group, run_group(group, fun)} end,
        timeout: @group_timeout_ms,
        on_timeout: :kill_task,
        ordered: false
      )

    {by_group, complete?} =
      Enum.reduce(stream, {%{}, true}, fn
        {:ok, {group, {rows, crashed?}}}, {acc, ok?} ->
          {Map.put(acc, group, rows), ok? and not crashed?}

        {:exit, _reason}, {acc, _ok?} ->
          # We can't tell which group timed out, but tracking the flag is
          # enough to skip caching the partial result.
          {acc, false}
      end)

    by_group = Enum.reduce(@groups, by_group, fn g, acc -> Map.put_new(acc, g, []) end)
    result = Map.put(by_group, :total_count, total_count(by_group))
    {result, complete?}
  end

  defp run_group(group, fun) do
    started = System.monotonic_time()

    {rows, fallback?, crashed?} =
      try do
        {rows, fallback?} = fun.()
        {rows, fallback?, false}
      rescue
        e ->
          Logger.error("[Cinegraph.Search] #{group} crashed: #{Exception.message(e)}")
          {[], true, true}
      end

    emit_group(started, group, rows, fallback?, crashed?)
    {rows, crashed?}
  end

  defp total_count(by_group) do
    Enum.reduce(@groups, 0, fn g, acc -> acc + length(Map.get(by_group, g, [])) end)
  end

  defp empty_result do
    %{films: [], people: [], lists: [], companies: [], total_count: 0}
  end

  # ============================================================================
  # Films
  # ============================================================================

  # Cap inner candidate set so common prefixes ("the") don't sort 100k+ rows.
  @prefix_inner_cap 50

  defp films(query, limit) do
    pattern_prefix = "#{query}%"

    # Prefix path: title only. ORs on lower(original_title) defeat the
    # idx_movies_lower_title_pattern index (forces seq scan on 1M+ rows).
    # original_title is covered by the trigram fallback below if needed.
    inner =
      from m in Movie,
        where: fragment("lower(?) LIKE ?", m.title, ^pattern_prefix),
        limit: @prefix_inner_cap,
        select: %{
          id: m.id,
          tmdb_id: m.tmdb_id,
          title: m.title,
          slug: m.slug,
          poster_path: m.poster_path,
          release_date: m.release_date
        }

    base =
      from m in subquery(inner),
        order_by: [
          desc: fragment("(lower(?) = ?)", m.title, ^query),
          desc_nulls_last: m.release_date
        ],
        limit: ^limit,
        select: %{
          id: m.id,
          tmdb_id: m.tmdb_id,
          title: m.title,
          slug: m.slug,
          poster_path: m.poster_path,
          release_date: m.release_date
        }

    rows = Repo.replica().all(base)
    {rows, fallback?} = maybe_film_fallback(rows, query, limit)

    rows = with_directors(rows)
    rows = Enum.map(rows, &shape_film/1)
    {rows, fallback?}
  end

  # Skip the trigram fallback whenever prefix found anything — fuzzy
  # matching is only useful when there is literally nothing to show.
  defp maybe_film_fallback(rows, _query, _limit) when rows != [] do
    {rows, false}
  end

  defp maybe_film_fallback(rows, query, limit) do
    seen_ids = MapSet.new(rows, & &1.id) |> MapSet.to_list()
    needed = limit - length(rows)

    extra =
      from(m in Movie,
        where: fragment("? <% ?", ^query, m.title) and m.id not in ^seen_ids,
        order_by: [desc_nulls_last: m.release_date],
        limit: ^needed,
        select: %{
          id: m.id,
          tmdb_id: m.tmdb_id,
          title: m.title,
          slug: m.slug,
          poster_path: m.poster_path,
          release_date: m.release_date
        }
      )
      |> Repo.replica().all()

    {rows ++ extra, extra != []}
  end

  defp shape_film(row) do
    year =
      case row.release_date do
        %Date{year: y} -> y
        _ -> nil
      end

    %{
      id: row.id,
      tmdb_id: row.tmdb_id,
      title: row.title,
      slug: to_string(row.slug),
      poster_path: row.poster_path,
      year: year,
      director: Map.get(row, :director)
    }
  end

  # Batch director lookup — one query for all film rows in this result.
  defp with_directors([]), do: []

  defp with_directors(rows) do
    movie_ids = Enum.map(rows, & &1.id)

    directors =
      from(c in Credit,
        join: p in Person,
        on: p.id == c.person_id,
        where: c.movie_id in ^movie_ids and c.job == "Director",
        select: {c.movie_id, p.name},
        order_by: [asc: c.id]
      )
      |> Repo.replica().all()
      |> Enum.reduce(%{}, fn {mid, name}, acc -> Map.put_new(acc, mid, name) end)

    Enum.map(rows, fn row -> Map.put(row, :director, Map.get(directors, row.id)) end)
  end

  # ============================================================================
  # People
  # ============================================================================

  defp people(query, limit) do
    pattern_prefix = "#{query}%"

    inner =
      from(p in Person,
        where: fragment("lower(?) LIKE ?", p.name, ^pattern_prefix),
        limit: @prefix_inner_cap,
        select: %{
          id: p.id,
          tmdb_id: p.tmdb_id,
          name: p.name,
          slug: p.slug,
          profile_path: p.profile_path,
          known_for_department: p.known_for_department,
          popularity: p.popularity
        }
      )

    prefix =
      from(p in subquery(inner),
        order_by: [desc_nulls_last: p.popularity, asc: p.name],
        limit: ^limit,
        select: %{
          id: p.id,
          tmdb_id: p.tmdb_id,
          name: p.name,
          slug: p.slug,
          profile_path: p.profile_path,
          known_for_department: p.known_for_department
        }
      )
      |> Repo.replica().all()

    {rows, fallback?} = maybe_people_fallback(prefix, query, limit)
    {Enum.map(rows, &shape_person/1), fallback?}
  end

  defp maybe_people_fallback(rows, _query, _limit) when rows != [] do
    {rows, false}
  end

  defp maybe_people_fallback(rows, query, limit) do
    seen_ids = MapSet.new(rows, & &1.id)
    needed = limit - length(rows)

    extra =
      from(p in Person,
        where: fragment("? <% ?", ^query, p.name) and p.id not in ^Enum.to_list(seen_ids),
        order_by: [desc_nulls_last: p.popularity, asc: p.name],
        limit: ^needed,
        select: %{
          id: p.id,
          tmdb_id: p.tmdb_id,
          name: p.name,
          slug: p.slug,
          profile_path: p.profile_path,
          known_for_department: p.known_for_department
        }
      )
      |> Repo.replica().all()

    {rows ++ extra, extra != []}
  end

  defp shape_person(row) do
    %{
      id: row.id,
      tmdb_id: row.tmdb_id,
      name: row.name,
      slug: to_string(row.slug),
      profile_path: row.profile_path,
      known_for_department: row.known_for_department
    }
  end

  # ============================================================================
  # Lists
  # ============================================================================

  defp lists(query, limit) do
    pattern_prefix = "#{query}%"

    prefix =
      from(l in MovieList,
        where:
          l.active == true and
            (fragment("lower(?) LIKE ?", l.name, ^pattern_prefix) or
               fragment("lower(?) LIKE ?", l.short_name, ^pattern_prefix)),
        order_by: [asc: l.display_order, asc: l.name],
        limit: ^limit,
        select: %{
          id: l.id,
          name: l.name,
          slug: l.slug,
          short_name: l.short_name,
          icon: l.icon
        }
      )
      |> Repo.replica().all()

    {rows, fallback?} = maybe_list_fallback(prefix, query, limit)
    {Enum.map(rows, &shape_list/1), fallback?}
  end

  defp maybe_list_fallback(rows, _query, _limit) when rows != [] do
    {rows, false}
  end

  defp maybe_list_fallback(rows, query, limit) do
    seen_ids = MapSet.new(rows, & &1.id)
    needed = limit - length(rows)

    extra =
      from(l in MovieList,
        where:
          l.active == true and
            fragment("? <% ?", ^query, l.name) and
            l.id not in ^Enum.to_list(seen_ids),
        order_by: [asc: l.display_order, asc: l.name],
        limit: ^needed,
        select: %{
          id: l.id,
          name: l.name,
          slug: l.slug,
          short_name: l.short_name,
          icon: l.icon
        }
      )
      |> Repo.replica().all()

    {rows ++ extra, extra != []}
  end

  defp shape_list(row) do
    %{
      id: row.id,
      name: row.name,
      slug: row.slug,
      short_name: row.short_name,
      icon: row.icon
    }
  end

  # ============================================================================
  # Companies
  # ============================================================================

  defp companies(query, limit) do
    pattern_prefix = "#{query}%"

    inner =
      from(c in ProductionCompany,
        where: fragment("lower(?) LIKE ?", c.name, ^pattern_prefix),
        limit: @prefix_inner_cap,
        select: %{
          id: c.id,
          tmdb_id: c.tmdb_id,
          name: c.name,
          logo_path: c.logo_path,
          origin_country: c.origin_country
        }
      )

    prefix =
      from(c in subquery(inner),
        order_by: [asc: c.name],
        limit: ^limit,
        select: %{
          id: c.id,
          tmdb_id: c.tmdb_id,
          name: c.name,
          logo_path: c.logo_path,
          origin_country: c.origin_country
        }
      )
      |> Repo.replica().all()

    {rows, fallback?} = maybe_company_fallback(prefix, query, limit)
    {Enum.map(rows, &shape_company/1), fallback?}
  end

  defp maybe_company_fallback(rows, _query, _limit) when rows != [] do
    {rows, false}
  end

  defp maybe_company_fallback(rows, query, limit) do
    seen_ids = MapSet.new(rows, & &1.id)
    needed = limit - length(rows)

    extra =
      from(c in ProductionCompany,
        where: fragment("? <% ?", ^query, c.name) and c.id not in ^Enum.to_list(seen_ids),
        order_by: [asc: c.name],
        limit: ^needed,
        select: %{
          id: c.id,
          tmdb_id: c.tmdb_id,
          name: c.name,
          logo_path: c.logo_path,
          origin_country: c.origin_country
        }
      )
      |> Repo.replica().all()

    {rows ++ extra, extra != []}
  end

  defp shape_company(row) do
    %{
      id: row.id,
      tmdb_id: row.tmdb_id,
      name: row.name,
      logo_path: row.logo_path,
      origin_country: row.origin_country
    }
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  @doc false
  def normalize_query(nil), do: ""

  def normalize_query(raw) when is_binary(raw) do
    raw
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  # ============================================================================
  # Telemetry
  # ============================================================================

  defp emit_global(started, query, cache_hit?) do
    duration_ms = ms_since(started)

    :telemetry.execute(
      [:cinegraph, :search, :global],
      %{duration_ms: duration_ms},
      %{query_length: String.length(query), cache_hit?: cache_hit?}
    )
  end

  defp emit_group(started, group, rows, fallback?, crashed?) do
    duration_ms = ms_since(started)

    :telemetry.execute(
      [:cinegraph, :search, :group],
      %{duration_ms: duration_ms, result_count: length(rows)},
      %{group: group, fallback?: fallback?, crashed?: crashed?}
    )
  end

  defp ms_since(start_mono) do
    System.convert_time_unit(System.monotonic_time() - start_mono, :native, :microsecond) / 1000.0
  end
end
