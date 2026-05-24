defmodule Cinegraph.Movies do
  @moduledoc """
  The Movies context.
  """

  import Ecto.Query, warn: false
  alias Cinegraph.Repo

  alias Cinegraph.Movies.{
    Movie,
    Person,
    Genre,
    Credit,
    Collection,
    Keyword,
    ProductionCompany,
    ProductionCountry,
    SpokenLanguage,
    MovieVideo,
    MovieReleaseDate,
    Availability,
    Filters
  }

  alias Cinegraph.Services.TMDb
  alias Cinegraph.{Collaborations, Metrics}
  alias Cinegraph.Metrics.ScoringService
  require Logger

  @doc """
  Base query for feature films only.

  Excludes adult content, partial imports, and short-form content (TV episodes,
  sports specials, etc.) by runtime threshold. Use this as the foundation for
  any "show me movies" query on public surfaces where TV/sports leakage is
  undesirable. The runtime nil-allowance keeps unimported runtime data from
  hiding otherwise valid films.
  """
  def feature_film_query do
    from(m in Movie,
      where: m.adult == false,
      where: m.import_status == "full",
      where: m.runtime > 45 or is_nil(m.runtime)
    )
  end

  @doc """
  Recent theatrical releases for the home page.

  Returns up to `limit` feature films released in the last `days` days,
  preloading score_cache via left join (so films without a score still appear).
  Sorted by overall_score desc (nulls last), then release_date desc.
  """
  def recent_theatrical_releases(opts \\ []) do
    today = Elixir.Keyword.get(opts, :today, Date.utc_today())
    days_back = Elixir.Keyword.get(opts, :days, 60)
    days_ahead = Elixir.Keyword.get(opts, :days_ahead, 14)
    limit = Elixir.Keyword.get(opts, :limit, 8)
    start_date = Date.add(today, -days_back)
    end_date = Date.add(today, days_ahead)

    from(m in feature_film_query(),
      left_join: s in assoc(m, :score_cache),
      where: m.release_date >= ^start_date and m.release_date <= ^end_date,
      order_by: [desc_nulls_last: s.overall_score, desc: m.release_date, asc: m.id],
      preload: [score_cache: s],
      limit: ^limit
    )
    |> Repo.replica().all()
  end

  @doc """
  Returns movies currently playing in theaters, as confirmed by the NowPlayingSweeper.

  Only includes fully-imported movies with `now_playing_last_seen` within the last
  3 days (the sweep staleness window). Returns an empty list (not an error) when
  the sweeper has never run.

  Options:
  - `:limit` — max results (default 100)
  - `:recency_days` — filter to movies with release_date within the last N days,
    useful for excluding old repertoire films (nil = no filter, default)
  - `:region` — filter to movies actively playing in the given ISO 3166-1 region
    (e.g. "US"), checked against per-region timestamps in now_playing_region_last_seen
  """
  def now_playing_movies(opts \\ []) do
    limit = Elixir.Keyword.get(opts, :limit, 100)
    recency_days = Elixir.Keyword.get(opts, :recency_days)
    region = Elixir.Keyword.get(opts, :region)
    stamp_cutoff = DateTime.add(DateTime.utc_now(), -3, :day)

    base =
      from(m in feature_film_query(),
        left_join: s in assoc(m, :score_cache),
        where: m.now_playing_last_seen >= ^stamp_cutoff,
        order_by: [desc_nulls_last: s.overall_score, desc: m.release_date, asc: m.id],
        preload: [score_cache: s],
        limit: ^limit
      )

    base
    |> then(fn q ->
      if recency_days do
        date_cutoff = Date.add(Date.utc_today(), -recency_days)
        where(q, [m], m.release_date >= ^date_cutoff)
      else
        q
      end
    end)
    |> Repo.replica().all()
    |> then(fn movies ->
      if region do
        Enum.filter(movies, &region_active?(&1, region, stamp_cutoff))
      else
        movies
      end
    end)
  end

  @doc """
  Returns the region codes where a movie is currently playing, based on per-region
  timestamps in `now_playing_region_last_seen`. A region is active if its timestamp
  is within `cutoff` (defaults to 3 days ago).
  """
  def active_now_playing_regions(movie, cutoff \\ nil) do
    cutoff = cutoff || DateTime.add(DateTime.utc_now(), -3, :day)
    regions = movie.now_playing_region_last_seen || %{}

    Enum.filter(Map.keys(regions), fn region ->
      case Map.get(regions, region) do
        nil ->
          false

        ts ->
          case DateTime.from_iso8601(ts) do
            {:ok, dt, _} -> DateTime.compare(dt, cutoff) in [:gt, :eq]
            _ -> false
          end
      end
    end)
  end

  @doc "Returns true if any region has a fresh now_playing timestamp."
  def currently_in_theaters?(movie, cutoff \\ nil) do
    active_now_playing_regions(movie, cutoff) != []
  end

  @doc "Returns true if the given region has a fresh now_playing timestamp."
  def region_active?(movie, region, cutoff \\ nil) do
    region in active_now_playing_regions(movie, cutoff)
  end

  @doc """
  Returns the list of movies with pagination, filtering, and sorting.
  Only returns fully imported movies by default.
  Includes discovery scores for movie cards when not using discovery metric sorting.
  """
  def list_movies(params \\ %{}) do
    sort = params["sort"] || "release_date_desc"

    query =
      Movie
      |> where([m], m.import_status == "full")
      |> Filters.apply_filters(params)

    # Only add discovery scores for display if we're NOT using discovery metric sorting
    # (discovery metric sorting in Filters handles its own scoring)
    query =
      if uses_discovery_sorting?(sort) do
        # Let Filters.apply_sorting handle the discovery scoring for these sorts
        query
      else
        # Add discovery scores for movie cards display, but don't affect sorting
        ScoringService.add_scores_for_display(query, "Balanced")
      end

    query
    |> Filters.apply_sorting(params)
    |> paginate(params)
  end

  defp uses_discovery_sorting?(sort) do
    sort in [
      "mob",
      "mob_asc",
      "mob_desc",
      "critics",
      "critics_asc",
      "critics_desc",
      "festival_recognition",
      "festival_recognition_asc",
      "festival_recognition_desc",
      "time_machine",
      "time_machine_asc",
      "time_machine_desc",
      "auteurs",
      "auteurs_asc",
      "auteurs_desc"
    ]
  end

  @doc """
  Counts total movies for pagination.
  Takes filters into account when counting.
  Only counts fully imported movies by default.
  """
  def count_movies(params \\ %{}) do
    query =
      Movie
      |> where([m], m.import_status == "full")
      |> Filters.apply_filters(params)

    # If we have genre filters, we need to count differently due to GROUP BY
    if params["genres"] && params["genres"] != [] do
      # Wrap the grouped query in a subquery and count the results
      from(m in subquery(query), select: count())
      |> Repo.replica().one()
    else
      # For all other filters, use normal aggregate
      Repo.replica().aggregate(query, :count, :id)
    end
  end

  @doc """
  Counts movies that belong to a specific canonical list.
  Uses JSONB containment to check if the list key exists in canonical_sources.
  """
  def count_movies_in_list(list_key) when is_binary(list_key) do
    from(m in Movie,
      where: m.import_status == "full",
      where: fragment("? \\? ?", m.canonical_sources, ^list_key)
    )
    |> Repo.replica().aggregate(:count, :id)
  end

  @doc """
  Counts full movies for each canonical list key in one query.
  """
  def count_movies_by_list_keys(list_keys) when is_list(list_keys) do
    list_keys = Enum.uniq(Enum.filter(list_keys, &is_binary/1))

    if list_keys == [] do
      %{}
    else
      from(m in Movie,
        join:
          key in fragment(
            "SELECT unnest(?::text[]) AS list_key",
            type(^list_keys, {:array, :string})
          ),
        on: fragment("? \\? ?", m.canonical_sources, field(key, :list_key)),
        where: m.import_status == "full",
        group_by: field(key, :list_key),
        select: {field(key, :list_key), count(m.id)}
      )
      |> Repo.replica().all()
      |> Map.new()
    end
  end

  @doc """
  Returns a small shelf of full movies from a canonical list ordered by source position.
  """
  def list_canonical_shelf_movies(source_key, limit \\ 12)
      when is_binary(source_key) and is_integer(limit) do
    position =
      dynamic(
        [m],
        fragment(
          "NULLIF(?->?->>'list_position', '')::int",
          m.canonical_sources,
          ^source_key
        )
      )

    from(m in Movie,
      where: m.import_status == "full",
      where: fragment("? \\? ?", m.canonical_sources, ^source_key),
      order_by: ^[asc_nulls_last: position, asc: :release_date, asc: :title],
      limit: ^limit
    )
    |> Repo.replica().all()
  end

  @doc """
  Returns the list of soft imported movies.
  These are movies that didn't meet quality criteria but are tracked.
  """
  def list_soft_imports(params \\ %{}) do
    Movie
    |> where([m], m.import_status == "soft")
    |> apply_sorting(params)
    |> paginate(params)
  end

  @doc """
  Counts soft imported movies.
  """
  def count_soft_imports do
    from(m in Movie, where: m.import_status == "soft")
    |> Repo.replica().aggregate(:count, :id)
  end

  # Sorting helper
  defp apply_sorting(query, params) do
    case params["sort"] do
      "title" ->
        order_by(query, [m], asc: m.title)

      "title_desc" ->
        order_by(query, [m], desc: m.title)

      "release_date" ->
        order_by(query, [m], asc: m.release_date)

      "release_date_desc" ->
        order_by(query, [m], desc: m.release_date)

      "rating" ->
        query
        |> order_by([m],
          desc:
            fragment(
              """
              (SELECT value FROM external_metrics 
               WHERE movie_id = ? AND source = 'tmdb' AND metric_type = 'rating_average'
               ORDER BY fetched_at DESC LIMIT 1)
              """,
              m.id
            )
        )

      "popularity" ->
        query
        |> order_by([m],
          desc:
            fragment(
              """
              (SELECT value FROM external_metrics 
               WHERE movie_id = ? AND source = 'tmdb' AND metric_type = 'popularity_score'
               ORDER BY fetched_at DESC LIMIT 1)
              """,
              m.id
            )
        )

      # default
      _ ->
        order_by(query, [m], desc: m.release_date)
    end
  end

  # Pagination helper
  defp paginate(query, params) do
    page = parse_page(params["page"])
    per_page = parse_per_page(params["per_page"])

    offset_val = (page - 1) * per_page

    query
    |> limit(^per_page)
    |> offset(^offset_val)
    |> Repo.replica().all()
  end

  defp parse_page(page_param) do
    case Integer.parse(page_param || "1") do
      {page, _} when page > 0 -> page
      _ -> 1
    end
  end

  defp parse_per_page(per_page_param) do
    case Integer.parse(per_page_param || "50") do
      {per_page, _} when per_page > 0 and per_page <= 100 -> per_page
      _ -> 50
    end
  end

  @doc """
  Gets a single movie.
  Uses read replica for better load distribution.
  """
  def get_movie!(id), do: Repo.replica().get!(Movie, id)

  @doc """
  Gets a movie by slug.
  Uses read replica for better load distribution.
  """
  def get_movie_by_slug!(slug) do
    Repo.replica().get_by!(Movie, slug: slug)
  end

  @doc """
  Gets a movie by TMDB ID.
  Uses read replica for display lookups.
  """
  def get_movie_by_tmdb_id(tmdb_id) do
    Repo.replica().get_by(Movie, tmdb_id: tmdb_id)
  end

  @doc """
  Quick search for movies by title, TMDb ID, or IMDb ID.
  Used by the audit interface for movie switching.

  ## Options

  - `:limit` - Maximum number of results (default: 20)

  ## Examples

      quick_search("Nosferatu")
      quick_search("550")        # TMDb ID
      quick_search("tt0137523")  # IMDb ID

  """
  def quick_search(query, opts \\ []) do
    limit = Elixir.Keyword.get(opts, :limit, 20)
    clean_query = String.trim(query)
    escaped_query = escape_like_wildcards(clean_query)

    from(m in Movie,
      where:
        fragment("LOWER(?) LIKE LOWER(?)", m.title, ^"%#{escaped_query}%") or
          fragment("LOWER(?) LIKE LOWER(?)", m.original_title, ^"%#{escaped_query}%") or
          fragment("CAST(? AS TEXT) = ?", m.tmdb_id, ^clean_query) or
          fragment("LOWER(?) = LOWER(?)", m.imdb_id, ^clean_query),
      select: %{
        id: m.id,
        title: m.title,
        original_title: m.original_title,
        tmdb_id: m.tmdb_id,
        imdb_id: m.imdb_id,
        release_date: m.release_date,
        slug: m.slug,
        poster_path: m.poster_path
      },
      order_by: [desc: m.release_date],
      limit: ^limit
    )
    |> Repo.replica().all()
  end

  @doc """
  Checks if a movie exists by TMDB ID.
  Used for deduplication during imports.
  Uses read replica since this is a read-only check.
  """
  def movie_exists?(tmdb_id) do
    from(m in Movie, where: m.tmdb_id == ^tmdb_id, select: true)
    |> Repo.replica().exists?()
  end

  @doc """
  Creates a movie.
  """
  def create_movie(attrs \\ %{}) do
    %Movie{}
    |> Movie.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a movie.
  """
  def update_movie(%Movie{} = movie, attrs) do
    movie
    |> Movie.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a movie.
  """
  def delete_movie(%Movie{} = movie) do
    Repo.delete(movie)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking movie changes.
  """
  def change_movie(%Movie{} = movie, attrs \\ %{}) do
    Movie.changeset(movie, attrs)
  end

  @doc """
  Gets a production company by slug or numeric ID.
  """
  def get_production_company_by_id_or_slug(id_or_slug) when is_integer(id_or_slug) do
    Repo.replica().get(ProductionCompany, id_or_slug)
  end

  def get_production_company_by_id_or_slug(id_or_slug) when is_binary(id_or_slug) do
    trimmed = String.trim(id_or_slug)

    case Repo.replica().get_by(ProductionCompany, slug: trimmed) do
      nil ->
        case Integer.parse(trimmed) do
          {id, ""} -> Repo.replica().get(ProductionCompany, id)
          _ -> nil
        end

      company ->
        company
    end
  end

  @doc """
  Lists production companies with movie-count stats for the company index.

  By default only companies attached to at least one fully imported movie are
  returned, so public cards match the movie grid users can browse.
  """
  def list_production_companies_with_stats(opts \\ []) do
    include_orphans? = Elixir.Keyword.get(opts, :include_orphans, false)
    category = Elixir.Keyword.get(opts, :category, "all")
    search = Elixir.Keyword.get(opts, :search, "")
    sort = Elixir.Keyword.get(opts, :sort, "films")
    limit = Elixir.Keyword.get(opts, :limit, if(include_orphans?, do: nil, else: 96))

    base_query =
      from(c in ProductionCompany,
        left_join: mpc in "movie_production_companies",
        on: mpc.production_company_id == c.id,
        left_join: m in Movie,
        on: m.id == mpc.movie_id and m.import_status == "full",
        group_by: c.id,
        select: %{
          id: c.id,
          tmdb_id: c.tmdb_id,
          name: c.name,
          slug: c.slug,
          description: c.description,
          website: c.website,
          logo_path: c.logo_path,
          logo_url: c.logo_url,
          hero_image_url: c.hero_image_url,
          origin_country: c.origin_country,
          metadata: c.metadata,
          inserted_at: c.inserted_at,
          updated_at: c.updated_at,
          movie_count: count(m.id),
          latest_movie_release_date: max(m.release_date),
          latest_movie_title:
            fragment(
              "(array_remove(array_agg(? ORDER BY ? DESC NULLS LAST), NULL))[1]",
              m.title,
              m.release_date
            )
        }
      )

    base_query =
      base_query
      |> maybe_filter_company_index_search(search)
      |> maybe_filter_company_index_category(category)
      |> maybe_exclude_orphan_companies(include_orphans?)
      |> order_company_index(sort)
      |> maybe_limit_company_index(limit)

    base_query
    |> Repo.replica().all()
    |> Enum.map(&put_company_index_flags/1)
  end

  @doc """
  Counts full movies by production-company id.
  """
  def count_movies_by_production_company_ids(company_ids) when is_list(company_ids) do
    company_ids =
      company_ids
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    if company_ids == [] do
      %{}
    else
      from(mpc in "movie_production_companies",
        join: m in Movie,
        on: m.id == mpc.movie_id,
        where: m.import_status == "full",
        where: mpc.production_company_id in ^company_ids,
        group_by: mpc.production_company_id,
        select: {mpc.production_company_id, count(m.id)}
      )
      |> Repo.replica().all()
      |> Map.new()
    end
  end

  @doc """
  Returns true when a production company's stored TMDb metadata is missing or stale.
  """
  def production_company_metadata_stale?(company, days \\ 180) when is_map(company) do
    tmdb = company.metadata |> ensure_map() |> Map.get("tmdb") |> ensure_map()

    missing_company_details? = is_nil(tmdb["company_details"])
    missing_company_images? = is_nil(tmdb["company_images"])

    missing_company_details? or missing_company_images? or
      stale_iso8601?(tmdb["details_fetched_at"], days) or
      stale_iso8601?(tmdb["images_fetched_at"], days)
  end

  @doc """
  Finds a production company by slug, name, local ID, or TMDb ID.
  """
  def find_production_company(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {id, ""} ->
        from(c in ProductionCompany, where: c.id == ^id or c.tmdb_id == ^id, limit: 1)
        |> Repo.replica().one()

      _ ->
        from(c in ProductionCompany,
          where: c.slug == ^trimmed or fragment("lower(?) = lower(?)", c.name, ^trimmed),
          limit: 1
        )
        |> Repo.replica().one()
    end
  end

  def find_production_company(id) when is_integer(id),
    do: get_production_company_by_id_or_slug(id)

  @doc """
  Returns production companies missing or stale TMDb metadata.
  """
  def list_production_companies_for_metadata_refresh(opts \\ []) do
    mode = Elixir.Keyword.get(opts, :mode, :missing)
    limit = Elixir.Keyword.get(opts, :limit, 100)
    stale_days = Elixir.Keyword.get(opts, :stale_days, 180)

    ProductionCompany
    |> order_by([c], asc: c.name)
    |> Repo.replica().all()
    |> Enum.filter(fn company ->
      case mode do
        :stale -> production_company_metadata_stale?(company, stale_days)
        _ -> production_company_missing_metadata?(company)
      end
    end)
    |> Enum.take(limit)
  end

  @doc """
  Enqueues a TMDb metadata refresh for a production company when missing/stale.
  """
  def enqueue_production_company_metadata_refresh(%ProductionCompany{} = company, opts \\ []) do
    force? = Elixir.Keyword.get(opts, :force, false)

    if force? or production_company_metadata_stale?(company) do
      Cinegraph.Workers.TMDbCompanyMetadataWorker.new(%{"company_id" => company.id})
      |> Oban.insert()
      |> case do
        {:ok, _job} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  rescue
    error ->
      Logger.warning(
        "Failed to enqueue company metadata refresh for #{company.id}: #{Exception.message(error)}"
      )

      {:error, error}
  end

  @doc """
  Backfills missing production company slugs.

  Duplicate names receive a stable TMDb/local ID suffix.
  """
  def backfill_production_company_slugs do
    ProductionCompany
    |> where([c], is_nil(c.slug) or c.slug == "")
    |> Repo.all()
    |> Enum.reduce_while({:ok, 0}, fn company, {:ok, count} ->
      slug = unique_company_slug(company)

      case update_company_slug(company, slug) do
        {:ok, _company} -> {:cont, {:ok, count + 1}}
        {:error, changeset} -> {:halt, {:error, company, changeset}}
      end
    end)
  end

  @doc """
  Refreshes stored TMDb metadata for a production company.

  Raw endpoint responses are stored under `metadata["tmdb"]`; display fields
  are derived only after both endpoint fetches succeed.
  """
  def refresh_production_company_metadata(company_or_id, opts \\ [])

  def refresh_production_company_metadata(%ProductionCompany{} = company, opts) do
    details_fetcher = Elixir.Keyword.get(opts, :details_fetcher, &TMDb.get_company/1)

    images_fetcher =
      Elixir.Keyword.get(opts, :images_fetcher, fn tmdb_id ->
        TMDb.get_company_images(tmdb_id, force_refresh: true)
      end)

    now = Elixir.Keyword.get(opts, :fetched_at, DateTime.utc_now() |> DateTime.truncate(:second))

    with {:ok, details} <- fetch_company_details(details_fetcher, company.tmdb_id),
         {:ok, images} <- fetch_company_images(images_fetcher, company.tmdb_id) do
      attrs = company_metadata_attrs(company, details, images, now)

      company
      |> ProductionCompany.changeset(attrs)
      |> Repo.update()
    end
  end

  def refresh_production_company_metadata(company_id, opts) when is_integer(company_id) do
    case Repo.get(ProductionCompany, company_id) do
      nil -> {:error, :not_found}
      company -> refresh_production_company_metadata(company, opts)
    end
  end

  @doc """
  Fetches a movie from TMDB and stores it in the database with all related data.
  """
  def fetch_and_store_movie_comprehensive(tmdb_id) do
    with {:ok, tmdb_data} <- TMDb.get_movie_ultra_comprehensive(tmdb_id) do
      store_movie_comprehensive_data(tmdb_data)
    end
  end

  @doc """
  Stores a comprehensive TMDb movie payload and all supported related data.
  """
  def store_movie_comprehensive_data(tmdb_data, opts \\ []) do
    with {:ok, movie} <- create_or_update_movie_from_tmdb(tmdb_data),
         :ok <- store_movie_availability(movie, tmdb_data, opts),
         :ok <- Metrics.store_tmdb_metrics(movie, tmdb_data),
         :ok <- process_movie_credits(movie, tmdb_data["credits"]),
         :ok <- process_movie_genres(movie, tmdb_data["genres"]),
         :ok <- process_movie_production_countries(movie, tmdb_data["production_countries"]),
         :ok <- process_movie_spoken_languages(movie, tmdb_data["spoken_languages"]),
         :ok <- process_movie_keywords(movie, tmdb_data["keywords"]),
         :ok <- process_movie_videos(movie, tmdb_data["videos"]),
         :ok <- process_movie_release_dates(movie, tmdb_data["release_dates"]),
         :ok <- process_movie_collection(movie, tmdb_data["belongs_to_collection"]),
         :ok <- process_movie_companies(movie, tmdb_data["production_companies"], opts),
         :ok <- process_movie_recommendations(movie, tmdb_data["recommendations"]),
         :ok <- process_movie_similar(movie, tmdb_data["similar"]),
         :ok <- process_movie_reviews(movie, tmdb_data["reviews"]),
         :ok <- process_movie_lists(movie, tmdb_data["lists"]) do
      {:ok, movie}
    end
  end

  defp store_movie_availability(movie, tmdb_data, opts) do
    store_fun =
      Elixir.Keyword.get(
        opts,
        :availability_store_fun,
        &Availability.store_tmdb_watch_providers/3
      )

    regions = Elixir.Keyword.get(opts, :availability_regions, Availability.configured_regions())
    payload = Map.get(tmdb_data, "watch_providers")

    case store_fun.(movie, payload, regions: regions) do
      {:ok, _results} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to normalize watch availability for movie #{movie.id}: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "Failed to normalize watch availability for movie #{movie.id}: #{Exception.message(error)}"
      )

      :ok
  end

  @doc """
  Creates or updates a movie from TMDB data.
  """
  def create_or_update_movie_from_tmdb(tmdb_data) do
    movie_attrs = Movie.from_tmdb(tmdb_data)

    case get_movie_by_tmdb_id(tmdb_data["id"]) do
      nil ->
        # Try to insert, but handle race condition where another process inserted it
        %Movie{}
        |> Movie.changeset(movie_attrs)
        |> Repo.insert()
        |> case do
          {:ok, movie} ->
            {:ok, movie}

          {:error, %Ecto.Changeset{errors: [tmdb_id: {"has already been taken", _}]}} ->
            # Race condition - movie was inserted by another process, fetch it
            case get_movie_by_tmdb_id(tmdb_data["id"]) do
              nil ->
                # Still doesn't exist somehow, return the original error
                %Movie{}
                |> Movie.changeset(movie_attrs)
                |> Repo.insert()

              existing_movie ->
                # Found the movie inserted by another process, update it instead
                existing_movie
                |> Movie.changeset(movie_attrs)
                |> Repo.update()
            end

          error ->
            error
        end

      existing_movie ->
        existing_movie
        |> Movie.changeset(movie_attrs)
        |> Repo.update()
    end
  end

  @doc """
  Creates a soft import movie record with minimal data.
  This is used for movies that don't meet quality criteria.
  """
  def create_soft_import_movie(tmdb_data) do
    # Create movie with minimal data and soft import status
    movie_attrs =
      Movie.from_tmdb(tmdb_data)
      |> Map.put(:import_status, "soft")

    changeset = Movie.changeset(%Movie{}, movie_attrs)

    case get_movie_by_tmdb_id(tmdb_data["id"]) do
      nil ->
        # Try to insert, but handle race condition
        Repo.insert(changeset)
        |> case do
          {:ok, movie} ->
            {:ok, movie}

          {:error, %Ecto.Changeset{errors: [tmdb_id: {"has already been taken", _}]}} ->
            # Race condition - movie was inserted by another process, fetch it
            case get_movie_by_tmdb_id(tmdb_data["id"]) do
              nil ->
                # Still doesn't exist somehow, return the original error
                Repo.insert(changeset)

              %Movie{import_status: "soft"} = existing_movie ->
                # Re-soft-import if it was already soft
                existing_movie
                |> Movie.changeset(%{import_status: "soft"})
                |> Repo.update()

              existing_movie ->
                # Leave full imports untouched
                {:ok, existing_movie}
            end

          error ->
            error
        end

      %Movie{import_status: "soft"} = existing_movie ->
        # Only re-soft-import if it was already soft
        existing_movie
        |> Movie.changeset(%{import_status: "soft"})
        |> Repo.update()

      existing_movie ->
        # Leave full imports untouched
        {:ok, existing_movie}
    end
  end

  # Person functions

  @doc """
  Gets a person by TMDB ID.
  Uses read replica for display lookups.
  """
  def get_person_by_tmdb_id(tmdb_id) do
    Repo.replica().get_by(Person, tmdb_id: tmdb_id)
  end

  @doc """
  Creates a person.
  """
  def create_person(attrs \\ %{}) do
    case %Person{}
         |> Person.changeset(attrs)
         |> Repo.insert() do
      {:ok, person} = result ->
        # Trigger PQS calculation for new person
        Cinegraph.Metrics.PQSTriggerStrategy.trigger_new_person(person.id)
        result

      error ->
        error
    end
  end

  @doc """
  Creates or updates a person from TMDB data.
  """
  def create_or_update_person_from_tmdb(tmdb_data) do
    changeset = Person.from_tmdb(tmdb_data)

    case get_person_by_tmdb_id(tmdb_data["id"]) do
      nil ->
        case Repo.insert(changeset) do
          {:ok, person} = result ->
            # Trigger PQS calculation for new person
            Cinegraph.Metrics.PQSTriggerStrategy.trigger_new_person(person.id)
            result

          error ->
            error
        end

      existing_person ->
        existing_person
        |> Person.changeset(changeset.changes)
        |> Repo.update()
    end
  end

  # Genre functions

  @doc """
  Syncs genres from TMDB.
  """
  def sync_genres do
    with {:ok, %{"genres" => genres}} <- TMDb.Client.get("/genre/movie/list") do
      Enum.each(genres, fn genre_data ->
        changeset = Genre.from_tmdb(genre_data)

        case Repo.get_by(Genre, tmdb_id: genre_data["id"]) do
          nil ->
            Repo.insert(changeset)

          existing_genre ->
            existing_genre
            |> Genre.changeset(changeset.changes)
            |> Repo.update()
        end
      end)

      {:ok, :genres_synced}
    end
  end

  @doc """
  Lists all genres.
  Uses read replica for better load distribution.
  """
  def list_genres do
    Repo.replica().all(Genre)
  end

  # Credit functions

  @doc """
  Creates a credit (cast or crew association).
  """
  def create_credit(attrs) do
    case %Credit{}
         |> Credit.changeset(attrs)
         |> Repo.insert(
           on_conflict: :replace_all,
           conflict_target: :credit_id
         ) do
      {:ok, credit} = result ->
        # Trigger PQS recalculation for credit changes
        if credit.person_id do
          Cinegraph.Metrics.PQSTriggerStrategy.trigger_credit_changes(credit.person_id)
        end

        result

      error ->
        error
    end
  end

  @doc """
  Process credits data from TMDb and store in database.
  Public wrapper for the internal process_movie_credits function.
  Used by DataRepairWorker to backfill missing credits.
  """
  def process_movie_credits_public(movie, credits_data) do
    process_movie_credits(movie, credits_data)
  end

  @doc """
  Gets credits for a movie.
  Uses read replica for better load distribution.
  """
  def get_movie_credits(movie_id) do
    Credit
    |> where([c], c.movie_id == ^movie_id)
    |> preload(:person)
    |> Repo.replica().all()
  end

  @doc """
  Gets movies for a person.
  Uses read replica for better load distribution.
  """
  def get_person_movies(person_id) do
    Credit
    |> where([c], c.person_id == ^person_id)
    |> preload(:movie)
    |> Repo.replica().all()
  end

  @doc """
  Gets movie keywords.
  Uses read replica for better load distribution.
  """
  def get_movie_keywords(movie_id) do
    movie = Repo.replica().get(Movie, movie_id)

    if movie do
      movie
      |> Repo.replica().preload(:keywords)
      |> Map.get(:keywords, [])
    else
      []
    end
  end

  @doc """
  Gets movie videos.
  Uses read replica for better load distribution.
  """
  def get_movie_videos(movie_id) do
    MovieVideo
    |> where([v], v.movie_id == ^movie_id)
    |> Repo.replica().all()
  end

  @doc """
  Gets movie release dates.
  Uses read replica for better load distribution.
  """
  def get_movie_release_dates(movie_id) do
    MovieReleaseDate
    |> where([rd], rd.movie_id == ^movie_id)
    |> Repo.replica().all()
  end

  @doc """
  Gets movie production companies.
  Uses read replica for better load distribution.
  """
  def get_movie_production_companies(movie_id) do
    movie = Repo.replica().get(Movie, movie_id)

    if movie do
      movie
      |> Repo.replica().preload(:production_companies)
      |> Map.get(:production_companies, [])
    else
      []
    end
  end

  @doc """
  Gets a movie by IMDb ID.
  Uses read replica for display lookups.
  """
  def get_movie_by_imdb_id(imdb_id) do
    Repo.replica().get_by(Movie, imdb_id: imdb_id)
  end

  @doc """
  Counts movies that are canonical in a specific source.
  Uses read replica for better load distribution.
  """
  def count_canonical_movies(source_key) do
    from(m in Movie, where: fragment("? \\? ?", m.canonical_sources, ^source_key))
    |> Repo.replica().aggregate(:count, :id)
  end

  @doc """
  Counts movies that are canonical in any source.
  Uses read replica for better load distribution.
  """
  def count_any_canonical_movies do
    from(m in Movie, where: m.canonical_sources != ^%{})
    |> Repo.replica().aggregate(:count, :id)
  end

  @doc """
  Gets all canonical movies for a specific source.
  """
  def list_canonical_movies(source_key, params \\ %{}) do
    Movie
    |> where([m], fragment("? \\? ?", m.canonical_sources, ^source_key))
    |> apply_sorting(params)
    |> paginate(params)
  end

  @doc """
  Updates canonical sources for a movie.
  """
  def update_canonical_sources(%Movie{} = movie, source_key, metadata) do
    current_sources = movie.canonical_sources || %{}

    updated_sources =
      Map.put(
        current_sources,
        source_key,
        Map.merge(
          %{
            "included" => true
          },
          metadata
        )
      )

    movie
    |> Movie.changeset(%{canonical_sources: updated_sources})
    |> Repo.update()
  end

  # Processing functions for comprehensive movie data

  defp process_movie_credits(_movie, nil), do: :ok

  defp process_movie_credits(movie, %{"cast" => cast, "crew" => crew}) do
    alias Cinegraph.Imports.QualityFilter

    # Process cast
    cast_count =
      Enum.reduce(cast, 0, fn cast_member, count ->
        # Check if person meets quality criteria
        if QualityFilter.should_import_person?(cast_member) do
          with {:ok, person} <- create_or_update_person_from_tmdb(cast_member),
               credit_attrs <- %{
                 movie_id: movie.id,
                 person_id: person.id,
                 credit_type: "cast",
                 character: cast_member["character"],
                 cast_order: cast_member["order"],
                 credit_id: cast_member["credit_id"]
               },
               {:ok, _credit} <- create_credit(credit_attrs) do
            count + 1
          else
            _ -> count
          end
        else
          count
        end
      end)

    # Process crew
    crew_count =
      Enum.reduce(crew, 0, fn crew_member, count ->
        # Always import directors regardless of quality criteria (Issue #474: festival inference needs them)
        # For other crew roles, apply quality filter
        should_import =
          crew_member["job"] == "Director" or QualityFilter.should_import_person?(crew_member)

        if should_import do
          with {:ok, person} <- create_or_update_person_from_tmdb(crew_member),
               credit_attrs <- %{
                 movie_id: movie.id,
                 person_id: person.id,
                 credit_type: "crew",
                 department: crew_member["department"],
                 job: crew_member["job"],
                 credit_id: crew_member["credit_id"]
               },
               {:ok, _credit} <- create_credit(credit_attrs) do
            count + 1
          else
            _ -> count
          end
        else
          count
        end
      end)

    if cast_count + crew_count > 0 do
      Collaborations.enqueue_movie_rebuild(movie)
    end

    :ok
  end

  defp process_movie_keywords(_movie, nil), do: :ok

  defp process_movie_keywords(movie, %{"keywords" => keywords}) do
    Enum.each(keywords, fn keyword_data ->
      case create_or_update_keyword(keyword_data) do
        {:ok, keyword} ->
          # Create movie_keyword association
          Repo.insert_all(
            "movie_keywords",
            [[movie_id: movie.id, keyword_id: keyword.id]],
            on_conflict: :nothing
          )

        {:error, reason} ->
          Logger.warning(
            "Failed to create/update keyword #{keyword_data["name"]}: #{inspect(reason)}"
          )
      end
    end)

    :ok
  end

  defp process_movie_videos(_movie, nil), do: :ok

  defp process_movie_videos(movie, %{"results" => videos}) do
    Enum.each(videos, fn video_data ->
      video_data
      |> MovieVideo.from_tmdb(movie.id)
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: :tmdb_id
      )
    end)

    :ok
  end

  defp process_movie_release_dates(_movie, nil), do: :ok

  defp process_movie_release_dates(movie, %{"results" => countries}) do
    Enum.each(countries, fn country_data ->
      changesets = MovieReleaseDate.from_tmdb_country(country_data, movie.id)

      Enum.each(changesets, fn changeset ->
        Repo.insert(changeset,
          on_conflict: :nothing,
          conflict_target: [:movie_id, :country_code, :release_type]
        )
      end)
    end)

    :ok
  end

  defp process_movie_collection(_movie, nil), do: :ok

  defp process_movie_collection(_movie, collection_data) do
    with {:ok, collection_details} <- TMDb.get_collection(collection_data["id"]),
         {:ok, _collection} <- create_or_update_collection(collection_details) do
      :ok
    else
      _ -> :ok
    end
  end

  defp process_movie_companies(_movie, nil, _opts), do: :ok

  defp process_movie_companies(movie, companies, opts) do
    enqueue_fun =
      Elixir.Keyword.get(
        opts,
        :company_metadata_enqueue_fun,
        &enqueue_production_company_metadata_refresh/1
      )

    Enum.each(companies, fn company_data ->
      case create_or_update_company_basic(company_data) do
        {:ok, company} ->
          Repo.insert_all(
            "movie_production_companies",
            [[movie_id: movie.id, production_company_id: company.id]],
            on_conflict: :nothing
          )

          maybe_enqueue_company_metadata(company, enqueue_fun)

        {:error, reason} ->
          Logger.warning(
            "Failed to create/update company #{company_data["name"]}: #{inspect(reason)}"
          )
      end
    end)

    :ok
  end

  defp maybe_enqueue_company_metadata(company, enqueue_fun) do
    case enqueue_fun.(company) do
      :ok ->
        :ok

      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to enqueue metadata refresh for company #{company.name}: #{inspect(reason)}"
        )
    end
  rescue
    error ->
      Logger.warning(
        "Company metadata enqueue failed for company #{company.name}: #{Exception.message(error)}"
      )
  end

  # Helper functions for creating/updating related entities

  defp create_or_update_keyword(keyword_data) do
    case Repo.get_by(Keyword, tmdb_id: keyword_data["id"]) do
      nil ->
        # Try to insert, but handle race condition
        keyword_data
        |> Keyword.from_tmdb()
        |> Repo.insert()
        |> case do
          {:ok, keyword} ->
            {:ok, keyword}

          {:error, %Ecto.Changeset{errors: [tmdb_id: {"has already been taken", _}]}} ->
            # Race condition - keyword was inserted by another process, fetch it
            case Repo.get_by(Keyword, tmdb_id: keyword_data["id"]) do
              nil ->
                # Still doesn't exist somehow, return the original error
                keyword_data
                |> Keyword.from_tmdb()
                |> Repo.insert()

              existing_keyword ->
                {:ok, existing_keyword}
            end

          error ->
            error
        end

      existing ->
        {:ok, existing}
    end
  end

  defp create_or_update_collection(collection_data) do
    case Repo.get_by(Collection, tmdb_id: collection_data["id"]) do
      nil ->
        # Try to insert, but handle race condition
        collection_data
        |> Collection.from_tmdb()
        |> Repo.insert()
        |> case do
          {:ok, collection} ->
            {:ok, collection}

          {:error, %Ecto.Changeset{errors: [tmdb_id: {"has already been taken", _}]}} ->
            # Race condition - collection was inserted by another process, fetch it
            case Repo.get_by(Collection, tmdb_id: collection_data["id"]) do
              nil ->
                # Still doesn't exist somehow, return the original error
                collection_data
                |> Collection.from_tmdb()
                |> Repo.insert()

              existing_collection ->
                {:ok, existing_collection}
            end

          error ->
            error
        end

      existing ->
        {:ok, existing}
    end
  end

  defp create_or_update_company_basic(company_data) do
    case Repo.get_by(ProductionCompany, tmdb_id: company_data["id"]) do
      nil ->
        # Try to insert, but handle race condition
        company_data
        |> company_basic_attrs()
        |> insert_company_basic()
        |> case do
          {:ok, company} ->
            {:ok, company}

          {:error, %Ecto.Changeset{errors: [tmdb_id: {"has already been taken", _}]}} ->
            # Race condition - company was inserted by another process, fetch it
            case Repo.get_by(ProductionCompany, tmdb_id: company_data["id"]) do
              nil ->
                # Still doesn't exist somehow, return the original error
                company_data
                |> company_basic_attrs()
                |> insert_company_basic()

              existing_company ->
                ensure_company_slug(existing_company)
            end

          error ->
            error
        end

      existing ->
        existing
        |> ProductionCompany.changeset(company_basic_attrs_for_existing(existing, company_data))
        |> Repo.update()
        |> case do
          {:ok, company} -> ensure_company_slug(company)
          error -> error
        end
    end
  end

  defp company_basic_attrs(company_data) do
    %{
      tmdb_id: company_data["id"],
      name: company_data["name"],
      logo_path: company_data["logo_path"],
      origin_country: company_data["origin_country"]
    }
  end

  defp company_basic_attrs_for_existing(%ProductionCompany{} = company, company_data) do
    attrs = company_basic_attrs(company_data)

    case company.slug do
      slug when is_binary(slug) and slug != "" ->
        attrs

      _ ->
        Map.put(
          attrs,
          :slug,
          unique_company_slug(%{company | name: attrs.name, tmdb_id: attrs.tmdb_id})
        )
    end
  end

  defp insert_company_basic(attrs) do
    changeset = ProductionCompany.changeset(%ProductionCompany{}, attrs)

    case Repo.insert(changeset) do
      {:ok, company} ->
        {:ok, company}

      {:error, %Ecto.Changeset{errors: [slug: {"has already been taken", _}]}} ->
        slug = unique_company_slug(%ProductionCompany{tmdb_id: attrs.tmdb_id, name: attrs.name})

        %ProductionCompany{}
        |> ProductionCompany.changeset(Map.put(attrs, :slug, slug))
        |> Repo.insert()

      error ->
        error
    end
  end

  defp ensure_company_slug(%ProductionCompany{slug: slug} = company)
       when is_binary(slug) and slug != "" do
    {:ok, company}
  end

  defp ensure_company_slug(%ProductionCompany{} = company) do
    update_company_slug(company, unique_company_slug(company))
  end

  defp update_company_slug(%ProductionCompany{} = company, slug) do
    company
    |> ProductionCompany.changeset(%{slug: slug})
    |> Repo.update()
  end

  defp unique_company_slug(%ProductionCompany{} = company) do
    base_slug =
      company.name
      |> to_string()
      |> ProductionCompany.slugify()
      |> case do
        "" -> "company"
        slug -> slug
      end

    cond do
      company_slug_available?(base_slug, company.id) ->
        base_slug

      company.tmdb_id ->
        candidate = "#{base_slug}-#{company.tmdb_id}"

        if company_slug_available?(candidate, company.id) do
          candidate
        else
          "#{candidate}-#{company.id || System.unique_integer([:positive])}"
        end

      company.id ->
        "#{base_slug}-#{company.id}"

      true ->
        base_slug
    end
  end

  defp company_slug_available?(slug, nil) do
    not Repo.exists?(from(c in ProductionCompany, where: c.slug == ^slug))
  end

  defp company_slug_available?(slug, company_id) do
    not Repo.exists?(from(c in ProductionCompany, where: c.slug == ^slug and c.id != ^company_id))
  end

  defp fetch_company_details(fetcher, tmdb_id) do
    case fetcher.(tmdb_id) do
      {:ok, details} -> {:ok, details}
      {:error, reason} -> {:error, {:company_details, reason}}
    end
  end

  defp fetch_company_images(fetcher, tmdb_id) do
    case fetcher.(tmdb_id) do
      {:ok, images} -> {:ok, images}
      {:error, reason} -> {:error, {:company_images, reason}}
    end
  end

  defp company_metadata_attrs(company, details, images, fetched_at) do
    selected_logo = select_company_logo(company, images)

    tmdb_metadata =
      company.metadata
      |> ensure_map()
      |> get_in(["tmdb"])
      |> ensure_map()
      |> Map.merge(%{
        "company_details" => details,
        "company_images" => images,
        "details_fetched_at" => DateTime.to_iso8601(fetched_at),
        "images_fetched_at" => DateTime.to_iso8601(fetched_at)
      })
      |> maybe_put_selected_logo(selected_logo)

    metadata =
      company.metadata
      |> ensure_map()
      |> Map.put("tmdb", tmdb_metadata)

    %{
      metadata: metadata,
      website: company_website(company, details),
      logo_url: company_logo_url(company, selected_logo)
    }
  end

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_value), do: %{}

  defp maybe_put_selected_logo(metadata, nil), do: metadata

  defp maybe_put_selected_logo(metadata, selected_logo),
    do: Map.put(metadata, "selected_logo", selected_logo)

  defp company_website(company, details) do
    case Map.get(details, "homepage") do
      homepage when is_binary(homepage) and homepage != "" -> homepage
      _ -> company.website
    end
  end

  defp company_logo_url(_company, %{
         "file_path" => file_path,
         "chosen_from" => "tmdb_company_images"
       })
       when is_binary(file_path) do
    tmdb_image_url(file_path, "original")
  end

  defp company_logo_url(_company, %{
         "file_path" => file_path,
         "chosen_from" => "tmdb_embedded_logo_path"
       })
       when is_binary(file_path) do
    tmdb_image_url(file_path, "w500")
  end

  defp company_logo_url(company, _selected_logo), do: company.logo_url

  defp select_company_logo(company, %{"logos" => logos}) when is_list(logos) do
    logos
    |> Enum.filter(&valid_company_logo?/1)
    |> Enum.sort_by(&company_logo_sort_key/1)
    |> List.first()
    |> case do
      nil ->
        select_company_logo(company, nil)

      logo ->
        %{
          "file_path" => logo["file_path"],
          "file_type" => company_logo_file_type(logo),
          "iso_639_1" => logo["iso_639_1"],
          "chosen_from" => "tmdb_company_images",
          "vote_average" => logo["vote_average"],
          "vote_count" => logo["vote_count"]
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    end
  end

  defp select_company_logo(%ProductionCompany{logo_path: path}, _images)
       when is_binary(path) and path != "" do
    %{
      "file_path" => path,
      "file_type" => "png",
      "chosen_from" => "tmdb_embedded_logo_path"
    }
  end

  defp select_company_logo(_company, _images), do: nil

  defp valid_company_logo?(%{"file_path" => path}) when is_binary(path) and path != "", do: true
  defp valid_company_logo?(_logo), do: false

  defp company_logo_sort_key(logo) do
    {
      if(company_logo_file_type(logo) == "svg", do: 0, else: 1),
      if(logo["iso_639_1"] in ["en", nil, ""], do: 0, else: 1),
      -(logo["vote_average"] || 0),
      -(logo["vote_count"] || 0)
    }
  end

  defp company_logo_file_type(%{"file_type" => type}) when is_binary(type) do
    type
    |> String.downcase()
    |> String.trim_leading(".")
  end

  defp company_logo_file_type(%{"file_path" => path}) when is_binary(path) do
    path
    |> Path.extname()
    |> String.downcase()
    |> String.trim_leading(".")
  end

  defp company_logo_file_type(_logo), do: nil

  defp tmdb_image_url(path, size), do: "https://image.tmdb.org/t/p/#{size}#{path}"

  defp put_company_index_flags(company) do
    company
    |> Map.put(:has_logo_url, present?(company.logo_url))
    |> Map.put(:has_logo, present?(company.logo_url) or present?(company.logo_path))
    |> Map.put(:has_svg_logo, company_svg_logo?(company))
  end

  defp maybe_filter_company_index_search(query, search) when is_binary(search) do
    search = String.trim(search)

    if search == "" do
      query
    else
      escaped = escape_like_wildcards(search)

      where(
        query,
        [c],
        fragment("LOWER(?) LIKE LOWER(?)", c.name, ^"%#{escaped}%") or
          fragment("LOWER(?) LIKE LOWER(?)", c.origin_country, ^"%#{escaped}%")
      )
    end
  end

  defp maybe_filter_company_index_search(query, _search), do: query

  defp maybe_filter_company_index_category(query, "major"),
    do: having(query, [_c, _mpc, m], count(m.id) >= 25)

  defp maybe_filter_company_index_category(query, "international"),
    do: where(query, [c], not is_nil(c.origin_country) and c.origin_country != "US")

  defp maybe_filter_company_index_category(query, "with-logos"),
    do:
      where(
        query,
        [c],
        (not is_nil(c.logo_url) and c.logo_url != "") or
          (not is_nil(c.logo_path) and c.logo_path != "")
      )

  defp maybe_filter_company_index_category(query, _category), do: query

  defp maybe_exclude_orphan_companies(query, true), do: query

  defp maybe_exclude_orphan_companies(query, false),
    do: having(query, [_c, _mpc, m], count(m.id) > 0)

  defp order_company_index(query, "name"),
    do: order_by(query, [c], asc: fragment("lower(?)", c.name))

  defp order_company_index(query, "newest"),
    do: order_by(query, [_c, _mpc, m], desc: max(m.release_date))

  defp order_company_index(query, _sort),
    do: order_by(query, [_c, _mpc, m], desc: count(m.id), desc: max(m.release_date))

  defp maybe_limit_company_index(query, nil), do: query

  defp maybe_limit_company_index(query, limit) when is_integer(limit) and limit > 0,
    do: limit(query, ^limit)

  defp maybe_limit_company_index(query, _limit), do: query

  defp company_svg_logo?(company) do
    company.metadata
    |> ensure_map()
    |> get_in(["tmdb", "selected_logo", "file_type"])
    |> case do
      type when is_binary(type) -> String.downcase(type) == "svg"
      _ -> false
    end
  end

  defp production_company_missing_metadata?(%ProductionCompany{} = company) do
    tmdb = company.metadata |> ensure_map() |> Map.get("tmdb") |> ensure_map()
    is_nil(tmdb["company_details"]) or is_nil(tmdb["company_images"])
  end

  defp stale_iso8601?(value, days) when is_binary(value) do
    with {:ok, fetched_at, _offset} <- DateTime.from_iso8601(value) do
      DateTime.diff(DateTime.utc_now(), fetched_at, :day) > days
    else
      _ -> true
    end
  end

  defp stale_iso8601?(_value, _days), do: true

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  @doc """
  Fetches full person details from TMDB.
  """
  def fetch_and_update_person(person_id) do
    with {:ok, person_data} <- TMDb.get_person_comprehensive(person_id),
         {:ok, person} <- create_or_update_person_from_tmdb(person_data) do
      {:ok, person}
    end
  end

  # Process recommendations and similar movies

  defp process_movie_recommendations(_movie, nil), do: :ok

  defp process_movie_recommendations(movie, %{"results" => results}) do
    Metrics.store_tmdb_recommendations(movie, results, "recommended")
    :ok
  end

  defp process_movie_similar(_movie, nil), do: :ok

  defp process_movie_similar(movie, %{"results" => results}) do
    Metrics.store_tmdb_recommendations(movie, results, "similar")
    :ok
  end

  defp process_movie_reviews(_movie, nil), do: :ok

  defp process_movie_reviews(movie, %{"results" => reviews}) do
    # Use the new Metrics module to store engagement metrics
    Metrics.store_tmdb_engagement_metrics(movie, %{"results" => reviews}, nil)
    :ok
  end

  defp process_movie_lists(_movie, nil), do: :ok

  defp process_movie_lists(movie, %{"results" => lists}) do
    # Use the new Metrics module to store engagement metrics
    Metrics.store_tmdb_engagement_metrics(movie, nil, %{"results" => lists})
    :ok
  end

  # Process genres
  defp process_movie_genres(_movie, nil), do: :ok

  defp process_movie_genres(movie, genres) when is_list(genres) do
    # First ensure all genres exist
    genre_records =
      Enum.map(genres, fn genre_data ->
        attrs = %{
          tmdb_id: genre_data["id"],
          name: genre_data["name"]
        }

        case Repo.get_by(Genre, tmdb_id: genre_data["id"]) do
          nil ->
            {:ok, genre} = Repo.insert(Genre.changeset(%Genre{}, attrs))
            genre

          existing_genre ->
            existing_genre
        end
      end)

    # Clear existing associations
    Repo.delete_all(from(mg in "movie_genres", where: mg.movie_id == ^movie.id))

    # Create new associations
    Enum.each(genre_records, fn genre ->
      Repo.insert_all("movie_genres", [[movie_id: movie.id, genre_id: genre.id]],
        on_conflict: :nothing,
        conflict_target: [:movie_id, :genre_id]
      )
    end)

    :ok
  end

  # Process production countries
  defp process_movie_production_countries(_movie, nil), do: :ok

  defp process_movie_production_countries(movie, countries) when is_list(countries) do
    # First ensure all countries exist
    country_records =
      Enum.map(countries, fn country_data ->
        attrs = %{
          iso_3166_1: country_data["iso_3166_1"],
          name: country_data["name"]
        }

        case Repo.get_by(ProductionCountry, iso_3166_1: country_data["iso_3166_1"]) do
          nil ->
            {:ok, country} = Repo.insert(ProductionCountry.changeset(%ProductionCountry{}, attrs))
            country

          existing_country ->
            existing_country
        end
      end)

    # Clear existing associations
    Repo.delete_all(from(mpc in "movie_production_countries", where: mpc.movie_id == ^movie.id))

    # Create new associations
    Enum.each(country_records, fn country ->
      Repo.insert_all(
        "movie_production_countries",
        [[movie_id: movie.id, production_country_id: country.id]],
        on_conflict: :nothing,
        conflict_target: [:movie_id, :production_country_id]
      )
    end)

    :ok
  end

  # Process spoken languages
  defp process_movie_spoken_languages(_movie, nil), do: :ok

  defp process_movie_spoken_languages(movie, languages) when is_list(languages) do
    # First ensure all languages exist
    language_records =
      Enum.map(languages, fn lang_data ->
        attrs = %{
          iso_639_1: lang_data["iso_639_1"],
          name: lang_data["name"] || lang_data["english_name"] || lang_data["iso_639_1"],
          english_name: lang_data["english_name"]
        }

        case Repo.get_by(SpokenLanguage, iso_639_1: lang_data["iso_639_1"]) do
          nil ->
            case Repo.insert(SpokenLanguage.changeset(%SpokenLanguage{}, attrs)) do
              {:ok, language} ->
                language

              {:error, _changeset} ->
                # If insert fails, skip this language
                nil
            end

          existing_language ->
            existing_language
        end
      end)

    # Clear existing associations
    Repo.delete_all(from(msl in "movie_spoken_languages", where: msl.movie_id == ^movie.id))

    # Create new associations (skip nil records)
    language_records
    |> Enum.reject(&is_nil/1)
    |> Enum.each(fn language ->
      Repo.insert_all(
        "movie_spoken_languages",
        [[movie_id: movie.id, spoken_language_id: language.id]],
        on_conflict: :nothing,
        conflict_target: [:movie_id, :spoken_language_id]
      )
    end)

    :ok
  end

  @doc "List movies in a disparity category, ordered by disparity score (ASC for perfect_harmony, DESC otherwise)."
  def list_movies_by_disparity_category(category, opts \\ []) do
    limit = Elixir.Keyword.get(opts, :limit, 50)
    offset = Elixir.Keyword.get(opts, :offset, 0)
    order = if category == "perfect_harmony", do: :asc, else: :desc

    from(m in feature_film_query(),
      join: s in assoc(m, :score_cache),
      where: s.disparity_category == ^category,
      where: s.mob_score > 0.0 or s.critics_score > 0.0,
      order_by: [{^order, s.disparity_score}, asc: m.id],
      limit: ^limit,
      offset: ^offset,
      preload: [score_cache: s]
    )
    |> Repo.replica().all()
  end

  @doc "List movies with the largest critic/audience gap."
  def top_disparity_movies(opts \\ []) do
    limit = Elixir.Keyword.get(opts, :limit, 50)

    from(m in Movie,
      join: s in assoc(m, :score_cache),
      where: not is_nil(s.disparity_score),
      order_by: [desc: s.disparity_score, asc: m.id],
      limit: ^limit,
      preload: [score_cache: s]
    )
    |> Repo.replica().all()
  end

  @doc """
  Returns a slim Ecto query for all fully-imported movies in a given decade.
  Projects only the fields needed by the prediction pipeline: id, release_date,
  canonical_sources, and a tmdb_data JSONB object containing budget and revenue.
  """
  def decade_movies_query(decade) do
    start_date = Date.new!(decade, 1, 1)
    end_date = Date.new!(decade + 9, 12, 31)

    from m in Movie,
      where: m.release_date >= ^start_date and m.release_date <= ^end_date,
      where: m.import_status == "full",
      select: %Movie{
        id: m.id,
        release_date: m.release_date,
        tmdb_data:
          fragment(
            "jsonb_build_object('budget', ?->'budget', 'revenue', ?->'revenue')",
            m.tmdb_data,
            m.tmdb_data
          ),
        canonical_sources: m.canonical_sources
      }
  end

  # Helper to escape SQL LIKE wildcards
  defp escape_like_wildcards(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
