defmodule Cinegraph.Workers.OscarDiscoveryWorker do
  @moduledoc """
  Worker to process Oscar ceremony data and queue movie creation jobs.
  
  This worker:
  1. Takes a ceremony record
  2. Processes each nominee
  3. Checks if the movie exists (by IMDb ID)
  4. Queues TMDbDetailsWorker if movie doesn't exist
  5. Creates/updates nomination records
  """
  
  use Oban.Worker,
    queue: :oscar_imports,
    max_attempts: 3,
    priority: 2
  
  alias Cinegraph.Repo
  alias Cinegraph.Cultural.{OscarCeremony, OscarCategory, OscarNomination}
  alias Cinegraph.Workers.TMDbDetailsWorker
  alias Cinegraph.Movies.{Movie, Person}
  import Ecto.Query
  require Logger
  
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"ceremony_id" => ceremony_id}}) do
    case Repo.get(OscarCeremony, ceremony_id) do
      nil ->
        Logger.error("Ceremony #{ceremony_id} not found")
        {:error, :ceremony_not_found}
      ceremony ->
        Logger.info("Processing Oscar ceremony #{ceremony.year}")
        
        # First ensure ceremony is enhanced with IMDb data
        ceremony = ensure_imdb_enhancement(ceremony)
        
        # Process each category
        results = ceremony.data["categories"]
        |> Enum.flat_map(fn category ->
          process_category(category, ceremony)
        end)
        
        summary = summarize_results(results)
        Logger.info("Oscar discovery complete for #{ceremony.year}: #{inspect(summary)}")
        
        :ok
    end
  end
  
  defp ensure_imdb_enhancement(ceremony) do
    if ceremony.data["imdb_matched"] do
      ceremony
    else
      Logger.info("Enhancing ceremony #{ceremony.year} with IMDb data...")
      
      case Cinegraph.Scrapers.ImdbOscarScraper.enhance_ceremony_with_imdb(ceremony) do
        {:ok, enhanced_data} ->
          changeset = OscarCeremony.changeset(ceremony, %{data: enhanced_data})
          
          case Repo.update(changeset) do
            {:ok, updated} -> updated
            {:error, _} -> ceremony
          end
          
        {:error, _} ->
          Logger.error("Failed to enhance ceremony #{ceremony.year}")
          ceremony
      end
    end
  end
  
  defp process_category(category, ceremony) do
    category_name = category["category"]
    
    category["nominees"]
    |> Enum.map(fn nominee ->
      process_nominee(nominee, category_name, ceremony)
    end)
  end
  
  defp process_nominee(nominee, category_name, ceremony) do
    film_imdb_id = nominee["film_imdb_id"]
    film_title = nominee["film"]
    
    cond do
      # Skip if no IMDb ID
      is_nil(film_imdb_id) ->
        Logger.debug("Skipping #{film_title} - no IMDb ID")
        %{action: :skipped, reason: :no_imdb_id, title: film_title}
      
      # Process the movie
      true ->
        process_movie_nominee(film_imdb_id, nominee, category_name, ceremony)
    end
  end
  
  defp process_movie_nominee(imdb_id, nominee, category_name, ceremony) do
    # Check if movie exists by IMDb ID
    existing_movie = Repo.get_by(Movie, imdb_id: imdb_id)
    
    if existing_movie do
      # Movie exists - just create/update nomination record
      create_nomination_record(existing_movie, nominee, category_name, ceremony)
      %{action: :updated, movie_id: existing_movie.id, title: existing_movie.title}
    else
      # Movie doesn't exist - queue creation via TMDb
      queue_movie_creation(imdb_id, nominee, category_name, ceremony)
    end
  end
  
  defp queue_movie_creation(imdb_id, nominee, category_name, ceremony) do
    # Queue TMDbDetailsWorker with IMDb ID
    # The details worker will handle the lookup and creation
    job_args = %{
      "imdb_id" => imdb_id,
      "source" => "oscar_import",
      "metadata" => %{
        "ceremony_year" => ceremony.year,
        "category" => category_name,
        "film_title" => nominee["film"],
        "winner" => nominee["winner"] || false
      }
    }
    
    case job_args
         |> TMDbDetailsWorker.new()
         |> Oban.insert() do
      {:ok, job} ->
        Logger.info("Queued movie creation for #{nominee["film"]} (#{imdb_id})")
        
        # We'll create the nomination record later when the movie exists
        # For now, track that we queued it
        %{action: :queued, imdb_id: imdb_id, title: nominee["film"], job_id: job.id}
        
      {:error, reason} ->
        Logger.error("Failed to queue movie creation: #{inspect(reason)}")
        %{action: :error, reason: reason, title: nominee["film"]}
    end
  end
  
  defp create_nomination_record(movie, nominee, category_name, ceremony) do
    # Find the category
    category = Repo.get_by(OscarCategory, name: category_name)
    
    if category do
      # Check if nomination already exists
      # Use a query to handle multiple results gracefully
      existing_count = from(n in OscarNomination,
        where: n.ceremony_id == ^ceremony.id and
               n.category_id == ^category.id and
               n.movie_id == ^movie.id,
        select: count(n.id)
      ) |> Repo.one()
      
      if existing_count > 0 do
        Logger.debug("Nomination already exists for #{movie.title} in #{category_name} (found #{existing_count})")
      else
        # Determine if we should track person (only for actor/director categories)
        person_id = if category.tracks_person do
          find_or_create_person(nominee)
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
        
        case %OscarNomination{}
             |> OscarNomination.changeset(attrs)
             |> Repo.insert() do
          {:ok, _} ->
            Logger.info("Created nomination for #{movie.title} in #{category_name}")
          {:error, changeset} ->
            Logger.error("Failed to create nomination: #{inspect(changeset.errors)}")
        end
      end
    else
      Logger.error("Category not found: #{category_name}")
    end
  end
  
  defp find_or_create_person(nominee) do
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
            
            case Repo.insert(%Person{} |> Person.imdb_changeset(attrs)) do
              {:ok, person} -> person.id
              {:error, _} -> nil
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
      updated: 0,
      queued: 0,
      skipped: 0,
      errors: 0
    }, fn result, acc ->
      case result.action do
        :updated -> %{acc | updated: acc.updated + 1}
        :queued -> %{acc | queued: acc.queued + 1}
        :skipped -> %{acc | skipped: acc.skipped + 1}
        :error -> %{acc | errors: acc.errors + 1}
      end
    end)
  end
end