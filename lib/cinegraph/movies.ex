defmodule Cinegraph.Movies do
  @moduledoc """
  The Movies context.
  """

  import Ecto.Query, warn: false
  alias Cinegraph.Repo
  alias Cinegraph.Movies.{Movie, Person, Genre, Credit, Collection, Keyword, 
                         ProductionCompany, MovieVideo, MovieReleaseDate}
  alias Cinegraph.Services.TMDb
  alias Cinegraph.ExternalSources

  @doc """
  Returns the list of movies.
  """
  def list_movies do
    Repo.all(Movie)
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
    # Process cast
    Enum.each(cast, fn cast_member ->
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
    end)

    # Process crew
    Enum.each(crew, fn crew_member ->
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
        Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:movie_id, :country_code, :type])
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
        [[movie_id: movie.id, production_company_id: company.id, inserted_at: DateTime.utc_now(), updated_at: DateTime.utc_now()]],
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

  defp process_movie_watch_providers(_movie, nil), do: :ok
  defp process_movie_watch_providers(movie, %{"results" => providers}) do
    # Store watch provider data
    # TODO: Create schema and storage for watch providers
    IO.puts("📺 Watch providers available in #{map_size(providers)} regions")
    :ok
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

  defp process_movie_alternative_titles(_movie, nil), do: :ok
  defp process_movie_alternative_titles(movie, %{"titles" => titles}) do
    # Store alternative titles by country
    # TODO: Create schema and storage for alternative titles
    IO.puts("🌍 Found #{length(titles)} alternative titles")
    :ok
  end

  defp process_movie_translations(_movie, nil), do: :ok
  defp process_movie_translations(movie, %{"translations" => translations}) do
    # Store translation data
    # TODO: Create schema and storage for translations
    IO.puts("🌐 Available in #{length(translations)} languages")
    :ok
  end
end