defmodule Cinegraph.Movies do
  @moduledoc """
  The Movies context.
  """

  import Ecto.Query, warn: false
  alias Cinegraph.Repo
  alias Cinegraph.Movies.{Movie, Person, Genre, Credit, Collection, Keyword, 
                         ProductionCompany, ProductionCountry, SpokenLanguage,
                         MovieVideo, MovieReleaseDate}
  alias Cinegraph.Services.TMDb
  alias Cinegraph.ExternalSources

  @doc """
  Returns the list of movies with pagination.
  Only returns fully imported movies by default.
  """
  def list_movies(params \\ %{}) do
    Movie
    |> where([m], m.import_status == "full")
    |> apply_sorting(params)
    |> paginate(params)
  end

  @doc """
  Counts total movies for pagination.
  Only counts fully imported movies by default.
  """
  def count_movies(_params \\ %{}) do
    from(m in Movie, where: m.import_status == "full")
    |> Repo.aggregate(:count, :id)
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
    |> Repo.aggregate(:count, :id)
  end

  # Sorting helper
  defp apply_sorting(query, params) do
    case params["sort"] do
      "title" -> order_by(query, [m], asc: m.title)
      "title_desc" -> order_by(query, [m], desc: m.title)
      "release_date" -> order_by(query, [m], asc: m.release_date)
      "release_date_desc" -> order_by(query, [m], desc: m.release_date)
      "rating" -> order_by(query, [m], desc: m.vote_average)
      "popularity" -> order_by(query, [m], desc: m.popularity)
      _ -> order_by(query, [m], desc: m.release_date) # default
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
    |> Repo.all()
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
  """
  def get_movie!(id), do: Repo.get!(Movie, id)

  @doc """
  Gets a movie by TMDB ID.
  """
  def get_movie_by_tmdb_id(tmdb_id) do
    Repo.get_by(Movie, tmdb_id: tmdb_id)
  end

  @doc """
  Checks if a movie exists by TMDB ID.
  Used for deduplication during imports.
  """
  def movie_exists?(tmdb_id) do
    from(m in Movie, where: m.tmdb_id == ^tmdb_id, select: true)
    |> Repo.exists?()
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
         :ok <- ExternalSources.store_tmdb_ratings(movie, tmdb_data),
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
    changeset = Movie.from_tmdb(tmdb_data)
    
    case get_movie_by_tmdb_id(tmdb_data["id"]) do
      nil ->
        Repo.insert(changeset)
      existing_movie ->
        existing_movie
        |> Movie.changeset(changeset.changes)
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
      Movie.from_tmdb(tmdb_data).changes
      |> Map.put(:import_status, "soft")
    
    changeset = Movie.changeset(%Movie{}, movie_attrs)
    
    case get_movie_by_tmdb_id(tmdb_data["id"]) do
      nil ->
        Repo.insert(changeset)
      existing_movie ->
        # If movie exists but was soft imported, we could upgrade it later
        existing_movie
        |> Movie.changeset(%{import_status: "soft"})
        |> Repo.update()
    end
  end

  # Person functions

  @doc """
  Gets a person by TMDB ID.
  """
  def get_person_by_tmdb_id(tmdb_id) do
    Repo.get_by(Person, tmdb_id: tmdb_id)
  end

  @doc """
  Creates a person.
  """
  def create_person(attrs \\ %{}) do
    %Person{}
    |> Person.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates or updates a person from TMDB data.
  """
  def create_or_update_person_from_tmdb(tmdb_data) do
    changeset = Person.from_tmdb(tmdb_data)
    
    case get_person_by_tmdb_id(tmdb_data["id"]) do
      nil ->
        Repo.insert(changeset)
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
  """
  def list_genres do
    Repo.all(Genre)
  end

  # Credit functions

  @doc """
  Creates a credit (cast or crew association).
  """
  def create_credit(attrs) do
    %Credit{}
    |> Credit.changeset(attrs)
    |> Repo.insert(
      on_conflict: :replace_all,
      conflict_target: :credit_id
    )
  end

  @doc """
  Gets credits for a movie.
  """
  def get_movie_credits(movie_id) do
    Credit
    |> where([c], c.movie_id == ^movie_id)
    |> preload(:person)
    |> Repo.all()
  end

  @doc """
  Gets movies for a person.
  """
  def get_person_movies(person_id) do
    Credit
    |> where([c], c.person_id == ^person_id)
    |> preload(:movie)
    |> Repo.all()
  end

  @doc """
  Gets movie keywords.
  """
  def get_movie_keywords(movie_id) do
    movie = Repo.get(Movie, movie_id)
    if movie do
      movie
      |> Repo.preload(:keywords)
      |> Map.get(:keywords, [])
    else
      []
    end
  end

  @doc """
  Gets movie videos.
  """
  def get_movie_videos(movie_id) do
    MovieVideo
    |> where([v], v.movie_id == ^movie_id)
    |> Repo.all()
  end

  @doc """
  Gets movie release dates.
  """
  def get_movie_release_dates(movie_id) do
    MovieReleaseDate
    |> where([rd], rd.movie_id == ^movie_id)
    |> Repo.all()
  end

  @doc """
  Gets movie production companies.
  """
  def get_movie_production_companies(movie_id) do
    movie = Repo.get(Movie, movie_id)
    if movie do
      movie
      |> Repo.preload(:production_companies)
      |> Map.get(:production_companies, [])
    else
      []
    end
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
      {:ok, keyword} = create_or_update_keyword(keyword_data)
      
      # Create movie_keyword association
      Repo.insert_all(
        "movie_keywords",
        [[movie_id: movie.id, keyword_id: keyword.id]],
        on_conflict: :nothing
      )
    end)
    
    :ok
  end

  defp process_movie_videos(_movie, nil), do: :ok
  defp process_movie_videos(movie, %{"results" => videos}) do
    Enum.each(videos, fn video_data ->
      video_data
      |> MovieVideo.from_tmdb(movie.id)
      |> Repo.insert(on_conflict: :nothing, conflict_target: :tmdb_id)
    end)
    
    :ok
  end

  defp process_movie_release_dates(_movie, nil), do: :ok
  defp process_movie_release_dates(movie, %{"results" => countries}) do
    Enum.each(countries, fn country_data ->
      changesets = MovieReleaseDate.from_tmdb_country(country_data, movie.id)
      
      Enum.each(changesets, fn changeset ->
        Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:movie_id, :country_code, :release_type])
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
      {:ok, company} = create_or_update_company_basic(company_data)
      
      # Create movie_production_companies association
      Repo.insert_all(
        "movie_production_companies",
        [[movie_id: movie.id, production_company_id: company.id]],
        on_conflict: :nothing
      )
    end)
    
    :ok
  end

  # Helper functions for creating/updating related entities

  defp create_or_update_keyword(keyword_data) do
    case Repo.get_by(Keyword, tmdb_id: keyword_data["id"]) do
      nil ->
        keyword_data
        |> Keyword.from_tmdb()
        |> Repo.insert()
      existing ->
        {:ok, existing}
    end
  end

  defp create_or_update_collection(collection_data) do
    case Repo.get_by(Collection, tmdb_id: collection_data["id"]) do
      nil ->
        collection_data
        |> Collection.from_tmdb()
        |> Repo.insert()
      existing ->
        {:ok, existing}
    end
  end

  defp create_or_update_company_basic(company_data) do
    case Repo.get_by(ProductionCompany, tmdb_id: company_data["id"]) do
      nil ->
        %ProductionCompany{}
        |> ProductionCompany.changeset(%{
          tmdb_id: company_data["id"],
          name: company_data["name"],
          logo_path: company_data["logo_path"],
          origin_country: company_data["origin_country"]
        })
        |> Repo.insert()
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
    ExternalSources.store_tmdb_recommendations(movie, results, "recommended")
  end

  defp process_movie_similar(_movie, nil), do: :ok
  defp process_movie_similar(movie, %{"results" => results}) do
    ExternalSources.store_tmdb_recommendations(movie, results, "similar")
  end


  defp process_movie_reviews(_movie, nil), do: :ok
  defp process_movie_reviews(movie, %{"results" => reviews}) do
    # Store review count as engagement metric
    review_count = length(reviews)
    
    # Calculate average rating if reviews have ratings
    avg_rating = if review_count > 0 do
      ratings = reviews 
        |> Enum.filter(& &1["author_details"]["rating"])
        |> Enum.map(& &1["author_details"]["rating"])
      
      if length(ratings) > 0 do
        Enum.sum(ratings) / length(ratings)
      else
        nil
      end
    else
      nil
    end
    
    # Store as external rating
    with {:ok, source} <- ExternalSources.get_or_create_source("tmdb") do
      ExternalSources.upsert_rating(%{
        movie_id: movie.id,
        source_id: source.id,
        rating_type: "engagement",
        value: review_count,
        scale_min: 0.0,
        scale_max: 1000.0,  # Arbitrary max for count
        sample_size: review_count,
        metadata: %{
          "average_rating" => avg_rating,
          "rated_reviews" => length(Enum.filter(reviews, & &1["author_details"]["rating"]))
        },
        fetched_at: DateTime.utc_now()
      })
    end
    
    :ok
  end

  defp process_movie_lists(_movie, nil), do: :ok
  defp process_movie_lists(movie, %{"results" => lists}) do
    # Store list appearances as popularity metric
    list_count = length(lists)
    
    # Count lists that might be culturally relevant
    cultural_lists = lists |> Enum.filter(fn list ->
      name = String.downcase(list["name"] || "")
      String.contains?(name, ["award", "oscar", "academy", "cannes", "criterion", 
                             "afi", "best", "greatest", "top", "essential", "classic"])
    end)
    
    with {:ok, source} <- ExternalSources.get_or_create_source("tmdb") do
      ExternalSources.upsert_rating(%{
        movie_id: movie.id,
        source_id: source.id,
        rating_type: "list_appearances",
        value: list_count,
        scale_min: 0.0,
        scale_max: 10000.0,  # Arbitrary max for count
        sample_size: list_count,
        metadata: %{
          "cultural_list_count" => length(cultural_lists),
          "cultural_list_names" => Enum.take(Enum.map(cultural_lists, & &1["name"]), 10)
        },
        fetched_at: DateTime.utc_now()
      })
    end
    
    :ok
  end

  # Process genres
  defp process_movie_genres(_movie, nil), do: :ok
  defp process_movie_genres(movie, genres) when is_list(genres) do
    # First ensure all genres exist
    genre_records = Enum.map(genres, fn genre_data ->
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
    country_records = Enum.map(countries, fn country_data ->
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
      Repo.insert_all("movie_production_countries", 
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
    language_records = Enum.map(languages, fn lang_data ->
      attrs = %{
        iso_639_1: lang_data["iso_639_1"],
        name: lang_data["name"] || lang_data["english_name"] || lang_data["iso_639_1"],
        english_name: lang_data["english_name"]
      }
      
      case Repo.get_by(SpokenLanguage, iso_639_1: lang_data["iso_639_1"]) do
        nil ->
          case Repo.insert(SpokenLanguage.changeset(%SpokenLanguage{}, attrs)) do
            {:ok, language} -> language
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
      Repo.insert_all("movie_spoken_languages", 
        [[movie_id: movie.id, spoken_language_id: language.id]], 
        on_conflict: :nothing,
        conflict_target: [:movie_id, :spoken_language_id]
      )
    end)
    
    :ok
  end

end