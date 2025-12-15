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
    Filters
  }

  alias Cinegraph.Services.TMDb
  alias Cinegraph.Metrics
  alias Cinegraph.Metrics.ScoringService
  require Logger

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
      "popular_opinion",
      "popular_opinion_asc",
      "industry_recognition",
      "industry_recognition_asc",
      "cultural_impact",
      "cultural_impact_asc",
      "people_quality",
      "people_quality_asc"
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
  Fetches a movie from TMDB and stores it in the database with all related data.
  """
  def fetch_and_store_movie_comprehensive(tmdb_id) do
    with {:ok, tmdb_data} <- TMDb.get_movie_ultra_comprehensive(tmdb_id),
         {:ok, movie} <- create_or_update_movie_from_tmdb(tmdb_data),
         :ok <- Metrics.store_tmdb_metrics(movie, tmdb_data),
         :ok <- process_movie_credits(movie, tmdb_data["credits"]),
         :ok <- process_movie_genres(movie, tmdb_data["genres"]),
         :ok <- process_movie_production_countries(movie, tmdb_data["production_countries"]),
         :ok <- process_movie_spoken_languages(movie, tmdb_data["spoken_languages"]),
         :ok <- process_movie_keywords(movie, tmdb_data["keywords"]),
         :ok <- process_movie_videos(movie, tmdb_data["videos"]),
         :ok <- process_movie_release_dates(movie, tmdb_data["release_dates"]),
         :ok <- process_movie_collection(movie, tmdb_data["belongs_to_collection"]),
         :ok <- process_movie_companies(movie, tmdb_data["production_companies"]),
         :ok <- process_movie_recommendations(movie, tmdb_data["recommendations"]),
         :ok <- process_movie_similar(movie, tmdb_data["similar"]),
         :ok <- process_movie_reviews(movie, tmdb_data["reviews"]),
         :ok <- process_movie_lists(movie, tmdb_data["lists"]) do
      {:ok, movie}
    end
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
    Enum.each(cast, fn cast_member ->
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
             } do
          create_credit(credit_attrs)
        end
      end
    end)

    # Process crew
    Enum.each(crew, fn crew_member ->
      # Check if person meets quality criteria
      if QualityFilter.should_import_person?(crew_member) do
        with {:ok, person} <- create_or_update_person_from_tmdb(crew_member),
             credit_attrs <- %{
               movie_id: movie.id,
               person_id: person.id,
               credit_type: "crew",
               department: crew_member["department"],
               job: crew_member["job"],
               credit_id: crew_member["credit_id"]
             } do
          create_credit(credit_attrs)
        end
      end
    end)

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

  defp process_movie_companies(_movie, nil), do: :ok

  defp process_movie_companies(movie, companies) do
    Enum.each(companies, fn company_data ->
      # For now, just create basic company record
      # Could fetch full details with TMDb.get_company(company_data["id"])
      case create_or_update_company_basic(company_data) do
        {:ok, company} ->
          # Create movie_production_companies association
          Repo.insert_all(
            "movie_production_companies",
            [[movie_id: movie.id, production_company_id: company.id]],
            on_conflict: :nothing
          )

        {:error, reason} ->
          Logger.warning(
            "Failed to create/update company #{company_data["name"]}: #{inspect(reason)}"
          )
      end
    end)

    :ok
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
        %ProductionCompany{}
        |> ProductionCompany.changeset(%{
          tmdb_id: company_data["id"],
          name: company_data["name"],
          logo_path: company_data["logo_path"],
          origin_country: company_data["origin_country"]
        })
        |> Repo.insert()
        |> case do
          {:ok, company} ->
            {:ok, company}

          {:error, %Ecto.Changeset{errors: [tmdb_id: {"has already been taken", _}]}} ->
            # Race condition - company was inserted by another process, fetch it
            case Repo.get_by(ProductionCompany, tmdb_id: company_data["id"]) do
              nil ->
                # Still doesn't exist somehow, return the original error
                %ProductionCompany{}
                |> ProductionCompany.changeset(%{
                  tmdb_id: company_data["id"],
                  name: company_data["name"],
                  logo_path: company_data["logo_path"],
                  origin_country: company_data["origin_country"]
                })
                |> Repo.insert()

              existing_company ->
                {:ok, existing_company}
            end

          error ->
            error
        end

      existing ->
        {:ok, existing}
    end
  end

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

  # Helper to escape SQL LIKE wildcards
  defp escape_like_wildcards(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
