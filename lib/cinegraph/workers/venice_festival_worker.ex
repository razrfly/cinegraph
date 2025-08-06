defmodule Cinegraph.Workers.VeniceFestivalWorker do
  @moduledoc """
  Worker to fetch and process Venice Film Festival data from IMDb.

  This worker:
  1. Fetches Venice Film Festival data for specified year(s)
  2. Creates/updates Venice organization and ceremony records
  3. Processes nominations and creates movie records
  4. Queues TMDb enrichment jobs for movies

  ## Job Arguments
  - `year` (integer) - Single year to process
  - `years` (list) - Multiple years to process
  - `options` (map) - Processing options
    - `create_movies` (boolean, default: true) - Create movie records
    - `queue_enrichment` (boolean, default: true) - Queue TMDb jobs
    - `max_concurrency` (integer, default: 3) - Concurrent fetches

  ## Examples

      # Process single year
      %{"year" => 2024}
      |> VeniceFestivalWorker.new()
      |> Oban.insert()
      
      # Process multiple years
      %{"years" => [2022, 2023, 2024], "options" => %{"max_concurrency" => 2}}
      |> VeniceFestivalWorker.new()
      |> Oban.insert()
      
  """

  use Oban.Worker,
    queue: :festival_import,
    max_attempts: 3,
    priority: 2,
    tags: ["venice", "festival", "scraper"]

  alias Cinegraph.Repo
  alias Cinegraph.Festivals
  alias Cinegraph.Festivals.{FestivalCeremony, FestivalNomination, FestivalCategory}
  alias Cinegraph.Workers.{TMDbDetailsWorker, FestivalDiscoveryWorker}
  alias Cinegraph.Scrapers.VeniceFilmFestivalScraper
  alias Cinegraph.Movies.{Movie, Person}
  alias Cinegraph.Services.TMDb
  import Ecto.Query
  require Logger

  # Venice-specific award categories that track people (directors, actors)
  @person_tracking_categories [
    # Often awarded to director
    "golden_lion",
    # Director awards
    "silver_lion",
    # Acting awards (Volpi Cup for Best Actor/Actress)
    "volpi_cup",
    # Young actor/actress award
    "mastroianni_award",
    # Often for directors
    "special_jury_prize"
  ]

  @film_tracking_categories [
    "golden_lion",
    "silver_lion",
    "special_jury_prize",
    "horizons",
    "luigi_de_laurentiis"
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    start_time = System.monotonic_time()

    case args do
      %{"year" => year} ->
        process_single_year(year, Map.get(args, "options", %{}), job)

      %{"years" => years} when is_list(years) ->
        process_multiple_years(years, Map.get(args, "options", %{}), job)

      _ ->
        Logger.error("Invalid Venice Festival Worker arguments: #{inspect(args)}")
        {:error, :invalid_arguments}
    end
    |> add_timing_metadata(job, start_time)
  end

  defp process_single_year(year, options, job) do
    Logger.info("Processing Venice Film Festival #{year}")

    with {:ok, festival_data} <- VeniceFilmFestivalScraper.fetch_festival_data(year),
         {:ok, ceremony} <-
           VeniceFilmFestivalScraper.create_or_update_ceremony(year, festival_data),
         {:ok, stats} <- process_ceremony_data(ceremony, festival_data, options, job) do
      Logger.info(
        "Successfully processed Venice #{year}: #{stats.nominations} nominations, #{stats.movies_queued} movies queued"
      )

      summary = %{
        year: year,
        ceremony_id: ceremony.id,
        status: "completed",
        nominations: stats.nominations,
        winners: stats.winners,
        movies_found: stats.movies_found,
        movies_queued: stats.movies_queued,
        categories_processed: stats.categories_processed
      }

      {:ok, summary}
    else
      {:error, reason} ->
        Logger.error("Failed to process Venice #{year}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp process_multiple_years(years, options, job) do
    max_concurrency = Map.get(options, "max_concurrency", 3)

    Logger.info(
      "Processing Venice Film Festival for #{length(years)} years with max_concurrency=#{max_concurrency}"
    )

    case VeniceFilmFestivalScraper.fetch_multiple_years(years, max_concurrency: max_concurrency) do
      {:ok, results} ->
        # Process each successful result
        summary_results =
          results
          |> Enum.map(fn {year, result} ->
            case result do
              {:ok, festival_data} ->
                case VeniceFilmFestivalScraper.create_or_update_ceremony(year, festival_data) do
                  {:ok, ceremony} ->
                    case process_ceremony_data(ceremony, festival_data, options, job) do
                      {:ok, stats} ->
                        Logger.info("Venice #{year}: #{stats.nominations} nominations processed")
                        {year, :ok, stats}

                      {:error, reason} ->
                        Logger.error(
                          "Failed to process ceremony data for Venice #{year}: #{inspect(reason)}"
                        )

                        {year, :error, reason}
                    end

                  {:error, reason} ->
                    Logger.error(
                      "Failed to create ceremony for Venice #{year}: #{inspect(reason)}"
                    )

                    {year, :error, reason}
                end

              {:error, reason} ->
                Logger.error("Failed to fetch Venice #{year}: #{inspect(reason)}")
                {year, :error, reason}
            end
          end)

        successes = Enum.count(summary_results, fn {_, status, _} -> status == :ok end)
        failures = Enum.count(summary_results, fn {_, status, _} -> status == :error end)

        Logger.info(
          "Venice multi-year processing completed: #{successes} successes, #{failures} failures"
        )

        {:ok,
         %{
           total_years: length(years),
           successful_years: successes,
           failed_years: failures,
           results: summary_results
         }}

      {:error, reason} ->
        Logger.error("Failed to fetch Venice data for multiple years: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp process_ceremony_data(ceremony, festival_data, options, job) do
    create_movies = Map.get(options, "create_movies", true)
    queue_enrichment = Map.get(options, "queue_enrichment", true)

    # Ensure we have the organization loaded
    ceremony_with_org =
      if Ecto.assoc_loaded?(ceremony.organization) do
        ceremony
      else
        Repo.preload(ceremony, :organization)
      end

    venice_org = ceremony_with_org.organization

    if is_nil(venice_org) do
      Logger.error("Venice organization not found for ceremony #{ceremony.id}")
      {:error, :organization_not_found}
    else
      # Process each award category
      stats = %{
        nominations: 0,
        winners: 0,
        movies_found: 0,
        movies_queued: 0,
        categories_processed: 0
      }

      awards = Map.get(festival_data, :awards, %{})

      final_stats =
        awards
        |> Enum.reduce(stats, fn {category_name, nominations}, acc_stats ->
          case process_award_category(
                 ceremony_with_org,
                 venice_org,
                 category_name,
                 nominations,
                 create_movies,
                 queue_enrichment,
                 job
               ) do
            {:ok, category_stats} ->
              %{
                nominations: acc_stats.nominations + category_stats.nominations,
                winners: acc_stats.winners + category_stats.winners,
                movies_found: acc_stats.movies_found + category_stats.movies_found,
                movies_queued: acc_stats.movies_queued + category_stats.movies_queued,
                categories_processed: acc_stats.categories_processed + 1
              }

            {:error, reason} ->
              Logger.warning(
                "Failed to process Venice category '#{category_name}': #{inspect(reason)}"
              )

              acc_stats
          end
        end)

      {:ok, final_stats}
    end
  end

  defp process_award_category(
         ceremony,
         venice_org,
         category_name,
         nominations,
         create_movies,
         queue_enrichment,
         job
       ) do
    # Get or create the festival category
    category = get_or_create_venice_category(venice_org.id, category_name)

    if is_nil(category) do
      Logger.error("Failed to create Venice category: #{category_name}")
      {:error, :category_creation_failed}
    else
      Logger.info(
        "Processing Venice category: #{category.name} (#{length(nominations)} nominations)"
      )

      # Process each nomination in this category
      category_stats = %{nominations: 0, winners: 0, movies_found: 0, movies_queued: 0}

      final_stats =
        nominations
        |> Enum.reduce(category_stats, fn nomination, acc ->
          case process_nomination(
                 ceremony,
                 category,
                 nomination,
                 create_movies,
                 queue_enrichment,
                 job
               ) do
            {:ok, nom_stats} ->
              %{
                nominations: acc.nominations + 1,
                winners: acc.winners + if(nom_stats.winner, do: 1, else: 0),
                movies_found: acc.movies_found + nom_stats.movies_found,
                movies_queued: acc.movies_queued + nom_stats.movies_queued
              }

            {:error, reason} ->
              Logger.warning("Failed to process Venice nomination: #{inspect(reason)}")
              acc
          end
        end)

      {:ok, final_stats}
    end
  end

  defp get_or_create_venice_category(organization_id, category_name) do
    # Try to get existing category
    case Festivals.get_category(organization_id, category_name) do
      nil ->
        # Create new category
        attrs = %{
          organization_id: organization_id,
          name: category_name,
          category_type: determine_category_type(category_name),
          tracks_person: category_tracks_person?(category_name),
          description: generate_category_description(category_name)
        }

        case Festivals.create_category(attrs) do
          {:ok, category} ->
            category

          {:error, changeset} ->
            Logger.error(
              "Failed to create Venice category #{category_name}: #{inspect(changeset.errors)}"
            )

            nil
        end

      existing_category ->
        existing_category
    end
  end

  defp determine_category_type(category_name) do
    cond do
      category_name in ["golden_lion"] -> "main_competition"
      category_name in ["volpi_cup", "mastroianni_award"] -> "acting"
      category_name in ["silver_lion", "special_jury_prize"] -> "directing"
      category_name in ["horizons"] -> "emerging_talent"
      category_name in ["luigi_de_laurentiis"] -> "debut_film"
      true -> "special_award"
    end
  end

  defp category_tracks_person?(category_name) do
    category_name in @person_tracking_categories
  end

  defp generate_category_description(category_name) do
    case category_name do
      "golden_lion" -> "The Golden Lion, the highest prize awarded at the Venice Film Festival"
      "silver_lion" -> "Silver Lion for Best Director"
      "volpi_cup" -> "Volpi Cup for Best Actor or Best Actress"
      "mastroianni_award" -> "Marcello Mastroianni Award for Best Young Actor or Actress"
      "special_jury_prize" -> "Special Jury Prize"
      "horizons" -> "Horizons (Orizzonti) Award for emerging talent"
      "luigi_de_laurentiis" -> "Luigi De Laurentiis Award for debut film"
      _ -> "Venice Film Festival Award"
    end
  end

  defp process_nomination(ceremony, category, nomination, create_movies, queue_enrichment, job) do
    films = Map.get(nomination, :films, [])
    people = Map.get(nomination, :people, [])
    is_winner = Map.get(nomination, :winner, false)

    # For Venice, we primarily work with films
    if length(films) > 0 do
      # Take the first film (Venice nominations usually have one film)
      film = List.first(films)

      case process_film_nomination(
             ceremony,
             category,
             film,
             people,
             is_winner,
             create_movies,
             queue_enrichment,
             job
           ) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    else
      Logger.warning("Venice nomination has no films: #{inspect(nomination)}")
      {:ok, %{winner: is_winner, movies_found: 0, movies_queued: 0}}
    end
  end

  defp process_film_nomination(
         ceremony,
         category,
         film,
         people,
         is_winner,
         create_movies,
         queue_enrichment,
         job
       ) do
    imdb_id = Map.get(film, :imdb_id)
    title = Map.get(film, :title)
    year = Map.get(film, :year)

    if is_nil(imdb_id) do
      Logger.warning("Venice nomination missing IMDb ID for film: #{title}")
      {:ok, %{winner: is_winner, movies_found: 0, movies_queued: 0}}
    else
      # Check if movie exists
      movie = Repo.get_by(Movie, imdb_id: imdb_id)

      {movie_found, movie_queued} =
        if is_nil(movie) && create_movies do
          # Queue TMDb job to create movie
          if queue_enrichment do
            queue_tmdb_job(imdb_id, title, year, job)
            {0, 1}
          else
            {0, 0}
          end
        else
          {1, 0}
        end

      # Create nomination record
      person_id = find_or_link_person(people, category.tracks_person)

      nomination_attrs = %{
        ceremony_id: ceremony.id,
        category_id: category.id,
        movie_id: movie && movie.id,
        person_id: person_id,
        won: is_winner,
        details: %{
          "film_title" => title,
          "film_year" => year,
          "film_imdb_id" => imdb_id,
          "people_data" => people,
          "source" => "venice_imdb_scraper"
        }
      }

      case Festivals.create_nomination(nomination_attrs) do
        {:ok, _nomination} ->
          {:ok, %{winner: is_winner, movies_found: movie_found, movies_queued: movie_queued}}

        {:error, changeset} ->
          Logger.error("Failed to create Venice nomination: #{inspect(changeset.errors)}")
          {:error, :nomination_creation_failed}
      end
    end
  end

  defp find_or_link_person(people, tracks_person) when tracks_person and length(people) > 0 do
    # For Venice, try to find person by IMDb ID
    person_data = List.first(people)
    person_imdb_id = Map.get(person_data, :imdb_id)

    if person_imdb_id do
      case Repo.get_by(Person, imdb_id: person_imdb_id) do
        nil ->
          # Could create person here, but for now just return nil
          # Person creation can be handled by separate jobs
          nil

        person ->
          person.id
      end
    else
      nil
    end
  end

  defp find_or_link_person(_, _), do: nil

  defp queue_tmdb_job(imdb_id, title, year, parent_job) do
    job_args = %{
      "imdb_id" => imdb_id,
      "title" => title,
      "year" => year,
      "source" => "venice_festival_worker"
    }

    case TMDbDetailsWorker.new(job_args) |> Oban.insert() do
      {:ok, job} ->
        Logger.debug("Queued TMDb job #{job.id} for #{title} (#{imdb_id})")
        :ok

      {:error, reason} ->
        Logger.error("Failed to queue TMDb job for #{title} (#{imdb_id}): #{inspect(reason)}")
        :error
    end
  end

  defp add_timing_metadata(result, job, start_time) do
    duration_ms =
      System.convert_time_unit(
        System.monotonic_time() - start_time,
        :native,
        :millisecond
      )

    # Add timing to job metadata
    metadata =
      Map.merge(job.meta || %{}, %{
        "duration_ms" => duration_ms,
        "completed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    case result do
      {:ok, summary} when is_map(summary) ->
        enhanced_summary =
          Map.merge(summary, %{
            duration_ms: duration_ms,
            worker: "VeniceFestivalWorker"
          })

        {:ok, enhanced_summary}

      other ->
        other
    end
  end

  @doc """
  Helper function to queue Venice festival processing jobs.

  ## Examples

      # Process single year
      VeniceFestivalWorker.queue_year(2024)
      
      # Process multiple years
      VeniceFestivalWorker.queue_years([2022, 2023, 2024])
      
  """
  def queue_year(year, options \\ %{}) do
    %{"year" => year, "options" => options}
    |> new()
    |> Oban.insert()
  end

  def queue_years(years, options \\ %{}) do
    %{"years" => years, "options" => options}
    |> new()
    |> Oban.insert()
  end
end
