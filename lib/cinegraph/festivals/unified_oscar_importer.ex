defmodule Cinegraph.Festivals.UnifiedOscarImporter do
  @moduledoc """
  Imports Oscar ceremony data into the unified festival awards structure.
  """
  
  alias Cinegraph.{Repo, Cultural, Festivals}
  alias Cinegraph.Movies.{Movie, Person}
  alias Cinegraph.Scrapers.ImdbOscarScraper
  import Ecto.Query
  require Logger
  
  @doc """
  Process all Oscar ceremonies and create/update movies with festival nominations.
  """
  def import_all_ceremonies(options \\ []) do
    # Get or create AMPAS organization
    {:ok, org} = Festivals.get_organization_by_abbreviation("AMPAS")
                 |> case do
                   nil -> Festivals.create_organization(%{
                     name: "Academy of Motion Picture Arts and Sciences",
                     abbreviation: "AMPAS",
                     country: "United States",
                     founded_year: 1927,
                     website: "https://www.oscars.org"
                   })
                   org -> {:ok, org}
                 end
    
    ceremonies = Cultural.list_oscar_ceremonies()
    
    Logger.info("Processing #{length(ceremonies)} Oscar ceremonies for unified import...")
    
    results = 
      ceremonies
      |> Enum.map(&import_ceremony(&1, org, options))
      |> summarize_results()
    
    Logger.info("Import complete: #{inspect(results)}")
    results
  end
  
  @doc """
  Import Oscar ceremony data directly from scraped data into the unified structure.
  This is the new entry point that bypasses the old oscar_ceremonies table.
  """
  def import_from_scraped_data(ceremony_data, organization, year, options \\ []) do
    Logger.info("Processing scraped Oscar data for year #{year}...")
    
    unless organization do
      raise "AMPAS organization not found. Cannot proceed with import."
    end
    
    # Calculate ceremony number (first ceremony was in 1929 for 1927-1928 films)
    ceremony_number = year - 1927
    
    # Create or get the festival ceremony
    {:ok, fest_ceremony} = Festivals.find_or_create_ceremony(
      organization.id,
      year,
      %{
        ceremony_number: ceremony_number,
        data: ceremony_data
      }
    )
    
    # Handle both atom and string keys from scraper
    # The scraper returns atom keys, but IMDb enhancement adds string keys
    categories = ceremony_data["categories"] || ceremony_data[:categories] || []
    
    Logger.info("Processing #{length(categories)} categories for year #{year}")
    
    # Process each category
    results = 
      categories
      |> Enum.flat_map(fn category ->
        process_category(category, fest_ceremony, organization, options)
      end)
    
    %{
      ceremony_year: year,
      movies_created: Enum.count(results, & &1.action == :created),
      movies_updated: Enum.count(results, & &1.action == :updated),
      movies_skipped: Enum.count(results, & &1.action == :skipped),
      total_nominees: Enum.count(results)
    }
  end
  
  @doc """
  Import a single Oscar ceremony into the unified structure.
  DEPRECATED: This expects data from oscar_ceremonies table which we're trying to eliminate.
  """
  def import_ceremony(oscar_ceremony, organization \\ nil, options \\ []) do
    Logger.info("Processing Oscar ceremony #{oscar_ceremony.year}...")
    
    # Get AMPAS organization if not provided
    organization = organization || Festivals.get_organization_by_abbreviation("AMPAS")
    
    unless organization do
      raise "AMPAS organization not found. Please run Cinegraph.Festivals.seed_festival_organizations() first."
    end
    
    # First, enhance with IMDb data if not already done
    oscar_ceremony = ensure_imdb_enhancement(oscar_ceremony)
    
    # Create or get the festival ceremony
    {:ok, fest_ceremony} = Festivals.find_or_create_ceremony(
      organization.id,
      oscar_ceremony.year,
      %{
        ceremony_number: oscar_ceremony.ceremony_number,
        data: oscar_ceremony.data
      }
    )
    
    # Process each category - handle both atom and string keys
    categories = oscar_ceremony.data["categories"] || oscar_ceremony.data[:categories] || []
    results = 
      categories
      |> Enum.flat_map(fn category ->
        process_category(category, fest_ceremony, organization, options)
      end)
    
    %{
      ceremony_year: oscar_ceremony.year,
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
  
  defp process_category(category, ceremony, organization, options) do
    # Handle both atom and string keys
    category_name = category["category"] || category[:category]
    nominees = category["nominees"] || category[:nominees] || []
    
    # Determine category type and person tracking
    {category_type, tracks_person} = determine_category_type(category_name)
    
    # Create or get the festival category
    {:ok, fest_category} = Festivals.find_or_create_category(
      organization.id,
      category_name,
      %{
        category_type: category_type,
        tracks_person: tracks_person
      }
    )
    
    nominees
    |> Enum.map(fn nominee ->
      process_nominee(nominee, fest_category, ceremony, options)
    end)
  end
  
  defp determine_category_type(category_name) do
    cond do
      String.contains?(category_name, ["Actor", "Actress", "Directing"]) -> {"person", true}
      String.contains?(category_name, ["Writing", "Cinematography", "Editing"]) -> {"person", true}
      String.contains?(category_name, ["Best Picture"]) -> {"film", false}
      String.contains?(category_name, ["Visual Effects", "Sound", "Makeup"]) -> {"technical", false}
      String.contains?(category_name, ["Documentary", "Animated", "International"]) -> {"film", false}
      String.contains?(category_name, ["Song", "Score"]) -> {"technical", false}
      String.contains?(category_name, ["Design", "Costume"]) -> {"technical", false}
      true -> {"special", false}
    end
  end
  
  defp process_nominee(nominee, category, ceremony, options) do
    # Handle both atom and string keys
    film_imdb_id = nominee["film_imdb_id"] || nominee[:film_imdb_id]
    film_title = nominee["film"] || nominee[:film]
    
    cond do
      # Skip if no IMDb ID
      is_nil(film_imdb_id) ->
        Logger.debug("Skipping #{film_title} - no IMDb ID")
        %{action: :skipped, reason: :no_imdb_id, title: film_title}
      
      # Process the movie
      true ->
        process_movie(film_imdb_id, nominee, category, ceremony, options)
    end
  end
  
  defp process_movie(imdb_id, nominee, category, ceremony, options) do
    # Check if movie exists
    existing_movie = Repo.get_by(Movie, imdb_id: imdb_id)
    
    if existing_movie do
      # Create nomination for existing movie
      create_festival_nomination(existing_movie, nominee, category, ceremony)
    else
      # Create new movie and nomination
      create_movie_with_nomination(imdb_id, nominee, category, ceremony, options)
    end
  end
  
  defp create_festival_nomination(movie, nominee, category, ceremony) do
    # Determine prize name based on category
    prize_name = if category.name == "Best Picture", do: "Academy Award", else: "Oscar"
    
    # Handle both atom and string keys
    is_winner = nominee["winner"] || nominee[:winner] || false
    nominee_name = nominee["name"] || nominee[:name]
    person_imdb_ids = nominee["person_imdb_ids"] || nominee[:person_imdb_ids] || []
    
    # Build nomination attributes
    attrs = %{
      ceremony_id: ceremony.id,
      category_id: category.id,
      movie_id: movie.id,
      person_id: nil, # Will be linked later
      won: is_winner,
      prize_name: prize_name,
      details: %{
        "nominee_names" => nominee_name,
        "person_imdb_ids" => person_imdb_ids
      }
    }
    
    case Festivals.create_nomination(attrs) do
      {:ok, _nomination} ->
        Logger.info("Created nomination for #{movie.title} in #{category.name}")
        %{action: :updated, movie_id: movie.id, title: movie.title}
      
      {:error, changeset} ->
        Logger.error("Failed to create nomination for #{movie.title}: #{inspect(changeset.errors)}")
        %{action: :error, reason: changeset.errors, title: movie.title}
    end
  end
  
  defp create_movie_with_nomination(imdb_id, nominee, category, ceremony, options) do
    if Keyword.get(options, :create_movies, true) do
      # Try to fetch from TMDb using IMDb ID
      case fetch_movie_from_tmdb(imdb_id) do
        {:ok, tmdb_data} ->
          # Create movie with full TMDb data
          attrs = Movie.from_tmdb(tmdb_data)
          
          changeset = %Movie{} |> Movie.changeset(attrs)
          
          case Repo.insert(changeset) do
            {:ok, movie} ->
              Logger.info("Created movie #{movie.title} from TMDb data")
              
              # Create the nomination
              create_festival_nomination(movie, nominee, category, ceremony)
              
              %{action: :created, movie_id: movie.id, title: movie.title}
            
            {:error, changeset} ->
              film_title = nominee["film"] || nominee[:film]
              Logger.error("Failed to create movie #{film_title}: #{inspect(changeset.errors)}")
              %{action: :error, reason: changeset.errors, title: film_title}
          end
          
        {:error, :not_found} ->
          film_title = nominee["film"] || nominee[:film]
          Logger.warning("No TMDb match for IMDb ID #{imdb_id} (#{film_title})")
          
          if Keyword.get(options, :create_partial, false) do
            # Create partial record as fallback
            create_partial_movie_record(imdb_id, nominee, category, ceremony)
          else
            %{action: :skipped, reason: :no_tmdb_match, title: film_title}
          end
          
        {:error, reason} ->
          film_title = nominee["film"] || nominee[:film]
          Logger.error("TMDb API error for #{imdb_id}: #{inspect(reason)}")
          %{action: :error, reason: reason, title: film_title}
      end
    else
      film_title = nominee["film"] || nominee[:film]
      Logger.debug("Skipping movie creation for #{film_title} - create_movies disabled")
      %{action: :skipped, reason: :create_disabled, title: film_title}
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
  
  defp create_partial_movie_record(imdb_id, nominee, category, ceremony) do
    # Fallback for movies not in TMDb
    film_year = nominee["film_year"] || nominee[:film_year] || ceremony.year - 1
    film_title = nominee["film"] || nominee[:film]
    
    attrs = %{
      imdb_id: imdb_id,
      title: film_title,
      release_date: (if film_year, do: Date.new!(film_year, 1, 1), else: nil),
      import_status: "oscar_only"
    }
    
    changeset = %Movie{} |> Movie.changeset(attrs)
    
    case Repo.insert(changeset) do
      {:ok, movie} ->
        Logger.info("Created partial movie record for #{movie.title}")
        
        # Create the nomination
        create_festival_nomination(movie, nominee, category, ceremony)
        
        %{action: :created_partial, movie_id: movie.id, title: movie.title}
        
      {:error, changeset} ->
        Logger.error("Failed to create partial record: #{inspect(changeset.errors)}")
        %{action: :error, reason: changeset.errors, title: film_title}
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
  Get statistics about Oscar data import status in the unified structure.
  """
  def import_stats do
    org = Festivals.get_organization_by_abbreviation("AMPAS")
    
    if org do
      ceremonies = Festivals.list_ceremonies(org.id)
      
      total_nominations = 
        from(n in Festivals.FestivalNomination,
          join: c in assoc(n, :ceremony),
          where: c.organization_id == ^org.id,
          select: count(n.id)
        )
        |> Repo.one()
      
      people_nominations = 
        from(n in Festivals.FestivalNomination,
          join: c in assoc(n, :ceremony),
          join: cat in assoc(n, :category),
          where: c.organization_id == ^org.id and cat.tracks_person == true,
          select: count(n.id)
        )
        |> Repo.one()
      
      %{
        total_ceremonies: length(ceremonies),
        total_nominations: total_nominations,
        people_nominations: people_nominations,
        organization: org.name
      }
    else
      %{
        total_ceremonies: 0,
        total_nominations: 0,
        people_nominations: 0,
        organization: "Not initialized"
      }
    end
  end
end