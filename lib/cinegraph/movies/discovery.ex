defmodule Cinegraph.Movies.Discovery do
  @moduledoc """
  Bounded, metadata-backed movie discovery for API consumers.

  Public identifiers are TMDb identifiers. Results are ordered by release date
  descending (nulls last), then TMDb movie ID descending. Cursors bind that
  position to the normalized filters and match modes that produced it.

  Cursor pagination is deterministic over the current corpus, but it does not
  provide snapshot isolation when movie metadata changes between requests.
  """

  import Ecto.Query

  alias Cinegraph.Movies.{Genre, Keyword, Movie}
  alias Cinegraph.Repo

  @max_query_length 100
  @max_filter_ids 10
  @default_first 12
  @max_first 50
  @default_keyword_limit 10
  @max_keyword_limit 50
  @genre_cache_name :movies_cache
  @genre_cache_key {:graphql_movie_discovery, :genre_vocabulary_v1}
  @genre_cache_ttl :timer.minutes(15)

  @type match_mode :: :all | :any

  @doc "Searches the keyword vocabulary using literal, case-insensitive substring matching."
  def search_keywords(query, limit \\ @default_keyword_limit)

  def search_keywords(query, limit) when is_binary(query) do
    with {:ok, query} <- validate_keyword_query(query),
         :ok <- validate_range("limit", limit, 1, @max_keyword_limit) do
      candidates =
        from(keyword in Keyword,
          where: fragment("strpos(lower(?), lower(?)) > 0", keyword.name, ^query),
          order_by: [
            asc:
              fragment(
                "CASE WHEN lower(?) = lower(?) THEN 0 WHEN strpos(lower(?), lower(?)) = 1 THEN 1 ELSE 2 END",
                keyword.name,
                ^query,
                keyword.name,
                ^query
              ),
            asc: fragment("lower(?)", keyword.name),
            asc: keyword.tmdb_id
          ],
          limit: ^limit,
          select: keyword.id
        )

      keywords =
        from(keyword in Keyword,
          where: keyword.id in subquery(candidates),
          left_join: movie_keyword in "movie_keywords",
          on: field(movie_keyword, :keyword_id) == keyword.id,
          left_join: movie in Movie,
          on:
            movie.id == field(movie_keyword, :movie_id) and
              movie.import_status == "full",
          group_by: [keyword.id, keyword.tmdb_id, keyword.name],
          order_by: [
            asc:
              fragment(
                "CASE WHEN lower(?) = lower(?) THEN 0 WHEN strpos(lower(?), lower(?)) = 1 THEN 1 ELSE 2 END",
                keyword.name,
                ^query,
                keyword.name,
                ^query
              ),
            asc: fragment("lower(?)", keyword.name),
            asc: keyword.tmdb_id
          ],
          select: %{
            tmdb_id: keyword.tmdb_id,
            name: keyword.name,
            movie_count: count(movie.id, :distinct)
          }
        )
        |> Repo.all()

      {:ok, keywords}
    end
  end

  def search_keywords(_, _), do: {:error, "query must be a string"}

  @doc "Lists the stable TMDb genre vocabulary with eligible movie counts."
  def list_genres do
    case Cachex.fetch(@genre_cache_name, @genre_cache_key, fn _key ->
           {:commit, query_genres(), ttl: @genre_cache_ttl}
         end) do
      {status, genres} when status in [:ok, :commit] -> {:ok, genres}
      {:commit, genres, _opts} -> {:ok, genres}
      {:error, _reason} -> {:ok, query_genres()}
    end
  end

  @doc "Invalidates cached genre vocabulary counts."
  def invalidate_genre_cache do
    Cachex.del(@genre_cache_name, @genre_cache_key)
  end

  @doc "Discovers fully imported movies matching the requested TMDb metadata IDs."
  def discover(args) when is_map(args) do
    with {:ok, filters} <- normalize_filters(args),
         :ok <- validate_known_ids(filters),
         {:ok, cursor} <- decode_cursor(Map.get(args, :after), filters) do
      first = Map.get(args, :first, @default_first)

      movies =
        Movie
        |> where([movie], movie.import_status == "full")
        |> filter_by_group(:keyword, filters.keyword_tmdb_ids, filters.keyword_match)
        |> filter_by_group(:genre, filters.genre_tmdb_ids, filters.genre_match)
        |> after_cursor(cursor)
        |> order_by([movie],
          desc_nulls_last: movie.release_date,
          desc: movie.tmdb_id
        )
        |> limit(^(first + 1))
        |> Repo.all()

      has_next_page = length(movies) > first

      page_movies =
        movies
        |> Enum.take(first)
        |> Repo.preload(
          keywords:
            from(keyword in Keyword,
              order_by: [asc: fragment("lower(?)", keyword.name), asc: keyword.tmdb_id]
            ),
          genres:
            from(genre in Genre,
              order_by: [asc: fragment("lower(?)", genre.name), asc: genre.tmdb_id]
            )
        )

      keyword_ids = MapSet.new(filters.keyword_tmdb_ids)
      genre_ids = MapSet.new(filters.genre_tmdb_ids)

      edges =
        Enum.map(page_movies, fn movie ->
          %{
            cursor: encode_cursor(movie, filters),
            node: %{
              movie: movie,
              matched_keywords:
                Enum.filter(movie.keywords, &MapSet.member?(keyword_ids, &1.tmdb_id)),
              matched_genres: Enum.filter(movie.genres, &MapSet.member?(genre_ids, &1.tmdb_id))
            }
          }
        end)

      {:ok,
       %{
         edges: edges,
         page_info: %{
           end_cursor: edges |> List.last() |> then(&(&1 && &1.cursor)),
           has_next_page: has_next_page
         }
       }}
    end
  end

  defp validate_keyword_query(query) do
    query = String.trim(query)

    cond do
      query == "" -> {:error, "query must not be blank"}
      String.length(query) > @max_query_length -> {:error, "query must be at most 100 characters"}
      true -> {:ok, query}
    end
  end

  defp query_genres do
    from(genre in Genre,
      left_join: movie_genre in "movie_genres",
      on: field(movie_genre, :genre_id) == genre.id,
      left_join: movie in Movie,
      on: movie.id == field(movie_genre, :movie_id) and movie.import_status == "full",
      group_by: [genre.id, genre.tmdb_id, genre.name],
      order_by: [asc: fragment("lower(?)", genre.name), asc: genre.tmdb_id],
      select: %{
        tmdb_id: genre.tmdb_id,
        name: genre.name,
        movie_count: count(movie.id, :distinct)
      }
    )
    |> Repo.all()
  end

  defp normalize_filters(args) do
    keyword_ids = args |> Map.get(:keyword_tmdb_ids, []) |> normalize_ids()
    genre_ids = args |> Map.get(:genre_tmdb_ids, []) |> normalize_ids()
    keyword_match = Map.get(args, :keyword_match, :all)
    genre_match = Map.get(args, :genre_match, :all)
    first = Map.get(args, :first, @default_first)

    with :ok <- validate_id_group("keywordTmdbIds", keyword_ids),
         :ok <- validate_id_group("genreTmdbIds", genre_ids),
         :ok <- validate_filter_presence(keyword_ids, genre_ids),
         :ok <- validate_match_mode("keywordMatch", keyword_match),
         :ok <- validate_match_mode("genreMatch", genre_match),
         :ok <- validate_range("first", first, 1, @max_first) do
      {:ok,
       %{
         keyword_tmdb_ids: keyword_ids,
         genre_tmdb_ids: genre_ids,
         keyword_match: keyword_match,
         genre_match: genre_match
       }}
    end
  end

  defp normalize_ids(nil), do: []
  defp normalize_ids(ids) when is_list(ids), do: ids |> Enum.uniq() |> Enum.sort()
  defp normalize_ids(value), do: value

  defp validate_id_group(name, ids) when is_list(ids) do
    cond do
      length(ids) > @max_filter_ids ->
        {:error, "#{name} accepts at most #{@max_filter_ids} unique IDs"}

      Enum.any?(ids, &(not is_integer(&1) or &1 <= 0)) ->
        {:error, "#{name} must contain only positive integers"}

      true ->
        :ok
    end
  end

  defp validate_id_group(name, _), do: {:error, "#{name} must be a list"}

  defp validate_filter_presence([], []),
    do: {:error, "At least one keywordTmdbIds or genreTmdbIds filter is required"}

  defp validate_filter_presence(_, _), do: :ok

  defp validate_match_mode(_, mode) when mode in [:all, :any], do: :ok
  defp validate_match_mode(name, _), do: {:error, "#{name} must be ALL or ANY"}

  defp validate_range(_name, value, minimum, maximum)
       when is_integer(value) and value >= minimum and value <= maximum,
       do: :ok

  defp validate_range(name, _, minimum, maximum),
    do: {:error, "#{name} must be between #{minimum} and #{maximum}"}

  defp validate_known_ids(filters) do
    with :ok <- validate_known_id_group(Keyword, "keyword", filters.keyword_tmdb_ids),
         :ok <- validate_known_id_group(Genre, "genre", filters.genre_tmdb_ids) do
      :ok
    end
  end

  defp validate_known_id_group(_, _, []), do: :ok

  defp validate_known_id_group(schema, label, ids) do
    known_ids =
      from(item in schema, where: item.tmdb_id in ^ids, select: item.tmdb_id)
      |> Repo.all()
      |> MapSet.new()

    unknown_ids = Enum.reject(ids, &MapSet.member?(known_ids, &1))

    case unknown_ids do
      [] -> :ok
      ids -> {:error, "Unknown #{label} TMDb IDs: #{Enum.join(ids, ", ")}"}
    end
  end

  defp filter_by_group(query, _, [], _), do: query

  defp filter_by_group(query, :keyword, tmdb_ids, match_mode) do
    matches =
      matching_movies_subquery("movie_keywords", :keyword_id, Keyword, tmdb_ids, match_mode)

    from([movie] in query,
      join: match in subquery(matches),
      on: match.movie_id == movie.id
    )
  end

  defp filter_by_group(query, :genre, tmdb_ids, match_mode) do
    matches =
      matching_movies_subquery("movie_genres", :genre_id, Genre, tmdb_ids, match_mode)

    from([movie] in query,
      join: match in subquery(matches),
      on: match.movie_id == movie.id
    )
  end

  defp matching_movies_subquery(join_table, foreign_key, schema, tmdb_ids, match_mode) do
    required_count = if match_mode == :all, do: length(tmdb_ids), else: 1

    from(join_row in join_table,
      join: metadata in ^schema,
      on: metadata.id == field(join_row, ^foreign_key),
      where: metadata.tmdb_id in ^tmdb_ids,
      group_by: field(join_row, :movie_id),
      having: count(field(join_row, ^foreign_key), :distinct) >= ^required_count,
      select: %{movie_id: field(join_row, :movie_id)}
    )
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, %{release_date: nil, tmdb_id: tmdb_id}) do
    where(query, [movie], is_nil(movie.release_date) and movie.tmdb_id < ^tmdb_id)
  end

  defp after_cursor(query, %{release_date: release_date, tmdb_id: tmdb_id}) do
    where(
      query,
      [movie],
      movie.release_date < ^release_date or is_nil(movie.release_date) or
        (movie.release_date == ^release_date and movie.tmdb_id < ^tmdb_id)
    )
  end

  defp encode_cursor(movie, filters) do
    %{
      "v" => 1,
      "f" => filter_fingerprint(filters),
      "d" => movie.release_date && Date.to_iso8601(movie.release_date),
      "i" => movie.tmdb_id
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_cursor(nil, _), do: {:ok, nil}
  defp decode_cursor("", _), do: {:error, "Invalid cursor"}

  defp decode_cursor(encoded, filters) when is_binary(encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, %{"v" => 1, "f" => fingerprint, "d" => date, "i" => tmdb_id}} <-
           Jason.decode(json),
         true <- is_binary(fingerprint) and is_integer(tmdb_id) and tmdb_id > 0,
         {:ok, release_date} <- decode_cursor_date(date),
         :ok <- validate_cursor_fingerprint(fingerprint, filters) do
      {:ok, %{release_date: release_date, tmdb_id: tmdb_id}}
    else
      {:error, :filter_mismatch} -> {:error, "Cursor does not match the requested filters"}
      _ -> {:error, "Invalid cursor"}
    end
  end

  defp decode_cursor(_, _), do: {:error, "Invalid cursor"}

  defp decode_cursor_date(nil), do: {:ok, nil}
  defp decode_cursor_date(date) when is_binary(date), do: Date.from_iso8601(date)
  defp decode_cursor_date(_), do: {:error, :invalid_date}

  defp validate_cursor_fingerprint(fingerprint, filters) do
    if Plug.Crypto.secure_compare(fingerprint, filter_fingerprint(filters)),
      do: :ok,
      else: {:error, :filter_mismatch}
  end

  defp filter_fingerprint(filters) do
    filter_binary =
      :erlang.term_to_binary({
        filters.keyword_tmdb_ids,
        filters.keyword_match,
        filters.genre_tmdb_ids,
        filters.genre_match
      })

    :sha256
    |> :crypto.hash(filter_binary)
    |> Base.url_encode64(padding: false)
  end
end
