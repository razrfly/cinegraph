defmodule Cinegraph.Cultural.OscarImporter do
  @moduledoc """
  Imports Oscar ceremony data into movies and creates award relationships.
  """
  
  alias Cinegraph.{Repo, Cultural}
  alias Cinegraph.Movies.{Movie, Person}
  alias Cinegraph.Cultural.{OscarCategory, OscarNomination}
  alias Cinegraph.Scrapers.ImdbOscarScraper
  import Ecto.Query
  require Logger
  
  @doc """
  Process all Oscar ceremonies and create/update movies with IMDb IDs.
  """
  def import_all_ceremonies(options \\ []) do
    ceremonies = Cultural.list_oscar_ceremonies()
    
    Logger.info("Processing #{length(ceremonies)} Oscar ceremonies...")
    
    results = 
      ceremonies
      |> Enum.map(&import_ceremony(&1, options))
      |> summarize_results()
    
    Logger.info("Import complete: #{inspect(results)}")
    results
  end
  
  @doc """
  Import a single Oscar ceremony and create/update movies.
  """
  def import_ceremony(ceremony, options \\ []) do
    Logger.info("Processing Oscar ceremony #{ceremony.year}...")
    
    # First, enhance with IMDb data if not already done
    ceremony = ensure_imdb_enhancement(ceremony)
    
    # Process each category
    results = 
      ceremony.data["categories"]
      |> Enum.flat_map(fn category ->
        process_category(category, ceremony, options)
      end)
    
    %{
      ceremony_year: ceremony.year,
      movies_created: Enum.count(results, & &1.action == :created),
      movies_updated: Enum.count(results, & &1.action == :updated),
      movies_skipped: Enum.count(results, & &1.action == :skipped),
      total_nominees: Enum.count(results)
    }
  end
  
  defp ensure_imdb_enhancement(ceremony) do
    if ceremony.data["imdb_matched"] do
      ceremony
    else
      Logger.info("Enhancing ceremony #{ceremony.year} with IMDb data...")
      
      case ImdbOscarScraper.enhance_ceremony_with_imdb(ceremony) do
        {:ok, enhanced_data} ->
          changeset = 
            ceremony
            |> Cultural.OscarCeremony.changeset(%{data: enhanced_data})
          
          case Repo.update(changeset) do
            {:ok, updated_ceremony} -> updated_ceremony
            {:error, _} -> ceremony
          end
          
        {:error, _} ->
          Logger.error("Failed to enhance ceremony #{ceremony.year}")
          ceremony
      end
    end
  end
  
  defp process_category(category, ceremony, options) do
    category_name = category["category"]
    
    category["nominees"]
    |> Enum.map(fn nominee ->
      process_nominee(nominee, category_name, ceremony, options)
    end)
  end
  
  defp process_nominee(nominee, category_name, ceremony, options) do
    film_imdb_id = nominee["film_imdb_id"]
    film_title = nominee["film"]
    
    cond do
      # Skip if no IMDb ID
      is_nil(film_imdb_id) ->
        Logger.debug("Skipping #{film_title} - no IMDb ID")
        %{action: :skipped, reason: :no_imdb_id, title: film_title}
      
      # Process the movie
      true ->
        process_movie(film_imdb_id, nominee, category_name, ceremony, options)
    end
  end
  
  defp process_movie(imdb_id, nominee, category_name, ceremony, options) do
    # Check if movie exists
    existing_movie = Repo.get_by(Movie, imdb_id: imdb_id)
    
    if existing_movie do
      # Update existing movie with Oscar data
      update_movie_oscar_data(existing_movie, nominee, category_name, ceremony)
    else
      # Create new movie
      create_movie_from_oscar(imdb_id, nominee, category_name, ceremony, options)
    end
  end
  
  defp update_movie_oscar_data(movie, nominee, category_name, ceremony) do
    # First update the movie's awards JSONB (for backward compatibility)
    update_movie_awards_jsonb(movie, nominee, category_name, ceremony)
    
    # Then create the nomination record
    case create_nomination_record(movie, nominee, category_name, ceremony) do
      {:ok, _nomination} ->
        Logger.info("Updated #{movie.title} with Oscar nomination")
        %{action: :updated, movie_id: movie.id, title: movie.title}
      
      {:error, changeset} ->
        Logger.error("Failed to create nomination for #{movie.title}: #{inspect(changeset.errors)}")
        %{action: :error, reason: changeset.errors, title: movie.title}
    end
  end
  
  defp update_movie_awards_jsonb(movie, nominee, category_name, ceremony) do
    # Keep updating the JSONB for now (can remove later)
    oscar_data = movie.awards || %{}
    
    new_nomination = %{
      "ceremony_year" => ceremony.year,
      "ceremony_number" => ceremony.ceremony_number,
      "category" => category_name,
      "winner" => nominee["winner"],
      "nominees" => nominee["name"],
      "person_imdb_ids" => nominee["person_imdb_ids"]
    }
    
    nominations = oscar_data["oscar_nominations"] || []
    updated_nominations = nominations ++ [new_nomination]
    updated_awards = Map.put(oscar_data, "oscar_nominations", updated_nominations)
    
    movie
    |> Movie.changeset(%{awards: updated_awards})
    |> Repo.update()
  end
  
  defp create_movie_from_oscar(imdb_id, nominee, category_name, ceremony, options) do
    if Keyword.get(options, :create_movies, true) do
      # Try to fetch from TMDb using IMDb ID
      case fetch_movie_from_tmdb(imdb_id) do
        {:ok, tmdb_data} ->
          # Create movie with full TMDb data
          attrs = Movie.from_tmdb(tmdb_data)
          
          # Add Oscar nomination data
          oscar_nomination = %{
            "ceremony_year" => ceremony.year,
            "ceremony_number" => ceremony.ceremony_number,
            "category" => category_name,
            "winner" => nominee["winner"],
            "nominees" => nominee["name"],
            "person_imdb_ids" => nominee["person_imdb_ids"]
          }
          
          attrs_with_oscar = Map.put(attrs, :awards, %{
            "oscar_nominations" => [oscar_nomination]
          })
          
          changeset = %Movie{} |> Movie.changeset(attrs_with_oscar)
          
          case Repo.insert(changeset) do
            {:ok, movie} ->
              Logger.info("Created movie #{movie.title} from TMDb data with Oscar nomination")
              
              # Create the nomination record
              create_nomination_record(movie, nominee, category_name, ceremony)
              
              # Enrichment now happens automatically via TMDbDetailsWorker pipeline
              
              %{action: :created, movie_id: movie.id, title: movie.title}
            
            {:error, changeset} ->
              Logger.error("Failed to create movie #{nominee["film"]}: #{inspect(changeset.errors)}")
              %{action: :error, reason: changeset.errors, title: nominee["film"]}
          end
          
        {:error, :not_found} ->
          Logger.warning("No TMDb match for IMDb ID #{imdb_id} (#{nominee["film"]})")
          
          if Keyword.get(options, :create_partial, false) do
            # Create partial record as fallback
            create_partial_movie_record(imdb_id, nominee, category_name, ceremony)
          else
            %{action: :skipped, reason: :no_tmdb_match, title: nominee["film"]}
          end
          
        {:error, reason} ->
          Logger.error("TMDb API error for #{imdb_id}: #{inspect(reason)}")
          %{action: :error, reason: reason, title: nominee["film"]}
      end
    else
      Logger.debug("Skipping movie creation for #{nominee["film"]} - create_movies disabled")
      %{action: :skipped, reason: :create_disabled, title: nominee["film"]}
    end
  end
  
  defp fetch_movie_from_tmdb(imdb_id) do
    # Use TMDb's find endpoint to look up by IMDb ID
    case Cinegraph.Services.TMDb.find_by_imdb_id(imdb_id) do
      {:ok, %{"movie_results" => [movie_data | _]}} ->
        # Found a match, now fetch full details
        Cinegraph.Services.TMDb.get_movie(movie_data["id"])
        
      {:ok, %{"movie_results" => []}} ->
        {:error, :not_found}
        
      error ->
        error
    end
  end
  
  defp create_partial_movie_record(imdb_id, nominee, category_name, ceremony) do
    # Fallback for movies not in TMDb
    film_year = nominee["film_year"] || ceremony.year - 1
    
    attrs = %{
      imdb_id: imdb_id,
      title: nominee["film"],
      release_date: (if film_year, do: Date.new!(film_year, 1, 1), else: nil),
      awards: %{
        "oscar_nominations" => [
          %{
            "ceremony_year" => ceremony.year,
            "ceremony_number" => ceremony.ceremony_number,
            "category" => category_name,
            "winner" => nominee["winner"],
            "nominees" => nominee["name"],
            "person_imdb_ids" => nominee["person_imdb_ids"]
          }
        ]
      },
      import_status: "oscar_only"
    }
    
    changeset = %Movie{} |> Movie.changeset(attrs)
    
    case Repo.insert(changeset) do
      {:ok, movie} ->
        Logger.info("Created partial movie record for #{movie.title}")
        
        # Create the nomination record
        create_nomination_record(movie, nominee, category_name, ceremony)
        
        %{action: :created_partial, movie_id: movie.id, title: movie.title}
        
      {:error, changeset} ->
        Logger.error("Failed to create partial record: #{inspect(changeset.errors)}")
        %{action: :error, reason: changeset.errors, title: nominee["film"]}
    end
  end
  
  # No longer used - replaced by standard OMDbEnrichmentWorker in the pipeline
  # defp queue_movie_enrichment(movie) do
  #   # Queue a job to fetch full movie data from TMDb/OMDb
  #   %{movie_id: movie.id, imdb_id: movie.imdb_id}
  #   |> Cinegraph.Workers.EnrichMovieWorker.new()
  #   |> Oban.insert()
  #   
  #   Logger.info("Queued enrichment job for #{movie.title}")
  # end
  
  defp create_nomination_record(movie, nominee, category_name, ceremony) do
    # Find the category
    category = Repo.get_by(OscarCategory, name: category_name)
    
    if category do
      # Determine if we should track person
      person_id = if category.tracks_person do
        find_or_create_person(nominee, category_name)
      else
        nil
      end
      
      # Create the nomination
      attrs = %{
        ceremony_id: ceremony.id,
        category_id: category.id,
        movie_id: movie.id,
        person_id: person_id,
        won: nominee["winner"] || false,
        details: %{
          "nominee_names" => nominee["name"],
          "person_imdb_ids" => nominee["person_imdb_ids"] || []
        }
      }
      
      %OscarNomination{}
      |> OscarNomination.changeset(attrs)
      |> Repo.insert()
    else
      Logger.error("Category not found: #{category_name}")
      {:error, :category_not_found}
    end
  end
  
  defp find_or_create_person(nominee, _category_name) do
    # For single-person categories, we can try to find/create the person
    # This is simplified - in reality we'd want better matching logic
    
    person_imdb_ids = nominee["person_imdb_ids"] || []
    person_name = nominee["name"]
    
    cond do
      # If we have an IMDb ID, try to find by that
      length(person_imdb_ids) == 1 ->
        imdb_id = hd(person_imdb_ids)
        case Repo.get_by(Person, imdb_id: imdb_id) do
          nil -> 
            # Create a basic person record
            attrs = %{
              name: person_name,
              imdb_id: imdb_id
            }
            
            case Repo.insert(%Person{} |> Person.changeset(attrs)) do
              {:ok, person} -> person.id
              {:error, changeset} -> 
                Logger.error("Failed to create person #{person_name}: #{inspect(changeset.errors)}")
                nil
            end
            
          person -> 
            person.id
        end
      
      # Otherwise skip person tracking for now
      true ->
        nil
    end
  end
  
  defp summarize_results(results) do
    Enum.reduce(results, %{
      total_ceremonies: 0,
      total_nominees: 0,
      movies_created: 0,
      movies_updated: 0,
      movies_skipped: 0
    }, fn result, acc ->
      %{
        total_ceremonies: acc.total_ceremonies + 1,
        total_nominees: acc.total_nominees + result.total_nominees,
        movies_created: acc.movies_created + result.movies_created,
        movies_updated: acc.movies_updated + result.movies_updated,
        movies_skipped: acc.movies_skipped + result.movies_skipped
      }
    end)
  end
  
  @doc """
  Get statistics about Oscar data import status.
  """
  def import_stats do
    ceremonies = Cultural.list_oscar_ceremonies()
    
    enhanced_count = 
      ceremonies
      |> Enum.count(fn c -> c.data["imdb_matched"] == true end)
    
    total_nominees = 
      ceremonies
      |> Enum.flat_map(fn c -> 
        c.data["categories"] || []
        |> Enum.flat_map(fn cat -> cat["nominees"] || [] end)
      end)
      |> length()
    
    nominees_with_imdb = 
      ceremonies
      |> Enum.flat_map(fn c -> 
        c.data["categories"] || []
        |> Enum.flat_map(fn cat -> cat["nominees"] || [] end)
      end)
      |> Enum.count(fn n -> n["film_imdb_id"] != nil end)
    
    # Count movies with Oscar nominations
    movies_with_oscars = 
      from(m in Movie,
        where: fragment("? -> 'oscar_nominations' IS NOT NULL", m.awards),
        select: count(m.id)
      )
      |> Repo.one()
    
    %{
      total_ceremonies: length(ceremonies),
      enhanced_ceremonies: enhanced_count,
      total_nominees: total_nominees,
      nominees_with_imdb_ids: nominees_with_imdb,
      movies_with_oscar_data: movies_with_oscars
    }
  end
end