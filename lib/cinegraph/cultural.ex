defmodule Cinegraph.Cultural do
  @moduledoc """
  The Cultural context manages cultural authorities, curated lists, and 
  Cultural Relevance Index (CRI) calculations for movies.
  """

  import Ecto.Query, warn: false
  alias Cinegraph.Repo

  alias Cinegraph.Cultural.{
    Authority,
    CuratedList,
    MovieListItem,
    MovieDataChange,
    CRIScore
  }

  alias Cinegraph.Festivals

  alias Cinegraph.Scrapers.OscarScraper
  alias Cinegraph.Events
  alias Cinegraph.Workers.UnifiedFestivalWorker
  require Logger

  # ========================================
  # UNIVERSAL FESTIVAL IMPORTS
  # ========================================

  @doc """
  Import any festival data for a specific year using the unified system.

  ## Parameters
    * `festival_key` - The festival source key (e.g., "cannes", "venice", "berlin")
    * `year` - The year to import
    * `options` - Import options
    
  ## Examples

      iex> Cinegraph.Cultural.import_festival_year("cannes", 2024)
      {:ok, %{year: 2024, job_id: 456, status: :queued}}
      
  """
  def import_festival_year(festival_key, year, options \\ []) do
    # Validate festival exists in database
    case Events.get_active_by_source_key(festival_key) do
      nil ->
        {:error, "Unknown festival: #{festival_key}"}

      festival_event ->
        Logger.info("Starting #{festival_event.name} import for year #{year}")

        job_args = %{
          "festival" => festival_key,
          "year" => year,
          "options" => Enum.into(options, %{})
        }

        # Use unique args to prevent duplicate jobs
        case UnifiedFestivalWorker.new(job_args,
               unique: [period: 60, fields: [:args, :worker]]
             )
             |> Oban.insert() do
          {:ok, job} ->
            {:ok,
             %{
               festival: festival_key,
               year: year,
               job_id: job.id,
               status: :queued,
               worker: "UnifiedFestivalWorker"
             }}

          {:error, %Ecto.Changeset{errors: [unique: {"has already been taken", _}]}} ->
            Logger.info(
              "#{festival_event.name} import for year #{year} already queued or running"
            )

            {:ok,
             %{
               festival: festival_key,
               year: year,
               status: :already_queued,
               worker: "UnifiedFestivalWorker"
             }}

          {:error, reason} ->
            Logger.error(
              "Failed to queue #{festival_event.name} import for year #{year}: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end

  @doc """
  Import any festival data for a range of years.

  ## Examples

      iex> Cinegraph.Cultural.import_festival_years("berlin", 2020..2024)
      {:ok, %{years: 2020..2024, job_id: 123, status: :queued}}
      
  """
  def import_festival_years(festival_key, start_year..end_year//_, options \\ []) do
    years = start_year..end_year |> Enum.to_list()

    # Validate festival exists
    case Events.get_active_by_source_key(festival_key) do
      nil ->
        {:error, "Unknown festival: #{festival_key}"}

      festival_event ->
        # Note: Converting range to list as the worker expects a list for multi-year processing
        job_args = %{
          "festival" => festival_key,
          "years" => years,
          "options" => Enum.into(options, %{})
        }

        Logger.info(
          "Starting #{festival_event.name} import for #{length(years)} years: #{inspect(years)}"
        )

        # Use unique args to prevent duplicate jobs
        case UnifiedFestivalWorker.new(job_args,
               unique: [period: 60, fields: [:args, :worker]]
             )
             |> Oban.insert() do
          {:ok, job} ->
            {:ok,
             %{
               festival: festival_key,
               years: start_year..end_year,
               year_count: length(years),
               job_id: job.id,
               status: :queued,
               worker: "UnifiedFestivalWorker"
             }}

          {:error, %Ecto.Changeset{errors: [unique: {"has already been taken", _}]}} ->
            Logger.info(
              "#{festival_event.name} import for years #{inspect(years)} already queued or running"
            )

            {:ok,
             %{
               festival: festival_key,
               years: start_year..end_year,
               year_count: length(years),
               status: :already_queued,
               worker: "UnifiedFestivalWorker"
             }}

          {:error, reason} ->
            Logger.error(
              "Failed to queue #{festival_event.name} import for years #{inspect(years)}: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end

  # ========================================
  # CULTURAL AUTHORITIES
  # ========================================

  @doc """
  Returns the list of cultural authorities.
  """
  def list_authorities do
    Repo.replica().all(Authority)
  end

  @doc """
  Gets a single authority.
  """
  def get_authority!(id), do: Repo.replica().get!(Authority, id)

  @doc """
  Gets an authority by name.
  """
  def get_authority_by_name(name) do
    Repo.replica().get_by(Authority, name: name)
  end

  @doc """
  Creates an authority.
  """
  def create_authority(attrs \\ %{}) do
    %Authority{}
    |> Authority.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an authority.
  """
  def update_authority(%Authority{} = authority, attrs) do
    authority
    |> Authority.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an authority.
  """
  def delete_authority(%Authority{} = authority) do
    Repo.delete(authority)
  end

  # ========================================
  # CURATED LISTS
  # ========================================

  @doc """
  Returns the list of curated lists, optionally filtered by authority.
  """
  def list_curated_lists(authority_id \\ nil) do
    query = from l in CuratedList, preload: [:authority]

    query =
      if authority_id do
        from l in query, where: l.authority_id == ^authority_id
      else
        query
      end

    Repo.replica().all(query)
  end

  @doc """
  Gets a single curated list.
  """
  def get_curated_list!(id) do
    Repo.replica().get!(CuratedList, id)
    |> Repo.replica().preload([:authority, :movie_list_items])
  end

  @doc """
  Creates a curated list.
  """
  def create_curated_list(attrs \\ %{}) do
    %CuratedList{}
    |> CuratedList.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a curated list.
  """
  def update_curated_list(%CuratedList{} = list, attrs) do
    list
    |> CuratedList.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a curated list.
  """
  def delete_curated_list(%CuratedList{} = list) do
    Repo.delete(list)
  end

  # ========================================
  # MOVIE LIST ITEMS
  # ========================================

  @doc """
  Gets movies in a curated list.
  """
  def get_list_movies(list_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(item in MovieListItem,
      join: movie in assoc(item, :movie),
      where: item.list_id == ^list_id,
      order_by: [asc: item.position, desc: item.inserted_at],
      limit: ^limit,
      preload: [movie: movie]
    )
    |> Repo.replica().all()
  end

  @doc """
  Gets curated lists that contain a specific movie.
  """
  def get_list_movies_for_movie(_movie_id, _opts \\ []) do
    # TODO: Fix the rank column issue with PostgreSQL
    # For now, return empty list since we don't have movie list items in the database yet
    []
  end

  @doc """
  Adds a movie to a curated list.
  """
  def add_movie_to_list(movie_id, list_id, attrs \\ %{}) do
    attrs = Map.merge(attrs, %{movie_id: movie_id, list_id: list_id})

    %MovieListItem{}
    |> MovieListItem.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Removes a movie from a curated list.
  """
  def remove_movie_from_list(movie_id, list_id, award_category \\ nil) do
    query =
      from item in MovieListItem,
        where: item.movie_id == ^movie_id and item.list_id == ^list_id

    query =
      if award_category do
        from item in query, where: item.award_category == ^award_category
      else
        query
      end

    Repo.delete_all(query)
  end

  # ========================================
  # CRI SCORING
  # ========================================

  @doc """
  Gets the latest CRI score for a movie.
  Uses read replica for better load distribution.
  """
  def get_latest_cri_score(movie_id) do
    from(score in CRIScore,
      where: score.movie_id == ^movie_id,
      order_by: [desc: score.calculated_at],
      limit: 1
    )
    |> Repo.replica().one()
  end

  @doc """
  Creates or updates a CRI score for a movie.
  """
  def upsert_cri_score(movie_id, score_value, components, version \\ "1.0") do
    attrs = %{
      movie_id: movie_id,
      score: score_value,
      components: components,
      version: version,
      calculated_at: DateTime.utc_now()
    }

    %CRIScore{}
    |> CRIScore.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Calculates Cultural Relevance Index for a movie.
  This is a simplified version - full implementation would be more complex.
  """
  def calculate_cri_score(movie_id) do
    # Get movie with all cultural data
    movie_cultural_data = get_movie_cultural_data(movie_id)

    components = %{
      "authority_presence" => calculate_authority_presence(movie_cultural_data),
      "list_appearances" => calculate_list_appearances(movie_cultural_data),
      "award_recognition" => calculate_award_recognition(movie_cultural_data),
      "cultural_impact" => calculate_cultural_impact(movie_cultural_data)
    }

    # Weighted average of components
    score =
      components["authority_presence"] * 0.3 +
        components["list_appearances"] * 0.25 +
        components["award_recognition"] * 0.35 +
        components["cultural_impact"] * 0.1

    # Scale to 0-100
    final_score = score * 100

    upsert_cri_score(movie_id, final_score, components)
  end

  # ========================================
  # MOVIE DATA CHANGES
  # ========================================

  @doc """
  Records a data change event for a movie.
  """
  def record_movie_change(movie_id, platform, change_type, attrs \\ %{}) do
    attrs =
      Map.merge(attrs, %{
        movie_id: movie_id,
        source_platform: platform,
        change_type: change_type
      })

    %MovieDataChange{}
    |> MovieDataChange.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets recent change activity for a movie.
  """
  def get_movie_change_activity(movie_id, days \\ 30) do
    since = DateTime.utc_now() |> DateTime.add(-days * 24 * 3600, :second)

    from(change in MovieDataChange,
      where: change.movie_id == ^movie_id and change.period_end >= ^since,
      order_by: [desc: change.period_end]
    )
    |> Repo.replica().all()
  end

  @doc """
  Gets Oscar nominations for a movie from the festival tables.
  """
  def get_movie_oscar_nominations(movie_id) do
    # Get the Oscar organization
    oscar_org = Festivals.get_or_create_oscar_organization()

    if oscar_org && oscar_org.id do
      from(nomination in Cinegraph.Festivals.FestivalNomination,
        join: ceremony in Cinegraph.Festivals.FestivalCeremony,
        on: nomination.ceremony_id == ceremony.id,
        join: category in Cinegraph.Festivals.FestivalCategory,
        on: nomination.category_id == category.id,
        left_join: person in Cinegraph.Movies.Person,
        on: nomination.person_id == person.id,
        where: nomination.movie_id == ^movie_id and ceremony.organization_id == ^oscar_org.id,
        order_by: [desc: ceremony.year, asc: category.name],
        select: %{
          ceremony_year: ceremony.year,
          ceremony_number: ceremony.ceremony_number,
          category_name: category.name,
          tracks_person: category.tracks_person,
          won: nomination.won,
          details: nomination.details,
          person: person
        }
      )
      |> Repo.replica().all()
    else
      []
    end
  end

  @doc """
  Gets ALL festival nominations for a movie from all organizations.
  Returns nominations grouped by organization with win/nomination counts.
  Uses read replica for better load distribution.
  """
  def get_movie_all_festival_nominations(movie_id) do
    from(nomination in Cinegraph.Festivals.FestivalNomination,
      join: ceremony in Cinegraph.Festivals.FestivalCeremony,
      on: nomination.ceremony_id == ceremony.id,
      join: org in Cinegraph.Festivals.FestivalOrganization,
      on: ceremony.organization_id == org.id,
      join: category in Cinegraph.Festivals.FestivalCategory,
      on: nomination.category_id == category.id,
      left_join: person in Cinegraph.Movies.Person,
      on: nomination.person_id == person.id,
      where: nomination.movie_id == ^movie_id,
      order_by: [asc: org.name, desc: ceremony.year, asc: category.name],
      select: %{
        organization_id: org.id,
        organization_name: org.name,
        organization_abbreviation: org.abbreviation,
        data_source: ceremony.data_source,
        ceremony_year: ceremony.year,
        ceremony_number: ceremony.ceremony_number,
        ceremony_name: ceremony.name,
        category_name: category.name,
        tracks_person: category.tracks_person,
        won: nomination.won,
        details: nomination.details,
        person: person
      }
    )
    |> Repo.replica().all()
    |> group_nominations_by_organization()
  end

  defp group_nominations_by_organization(nominations) do
    nominations
    |> Enum.group_by(& &1.organization_id)
    |> Enum.map(fn {_org_id, noms} ->
      first = hd(noms)

      %{
        organization_id: first.organization_id,
        organization_name: first.organization_name,
        organization_abbreviation: first.organization_abbreviation,
        data_source: first.data_source,
        total_wins: Enum.count(noms, & &1.won),
        total_nominations: Enum.count(noms, &(not &1.won)),
        nominations: noms
      }
    end)
    |> Enum.sort_by(&organization_sort_key/1)
  end

  # Sort organizations by prestige (Academy Awards first, then alphabetically)
  defp organization_sort_key(%{organization_name: name}) do
    case name do
      "Academy of Motion Picture Arts and Sciences" -> {0, name}
      "British Academy of Film and Television Arts" -> {1, name}
      "Hollywood Foreign Press Association" -> {2, name}
      _ -> {3, name}
    end
  end

  # ========================================
  # OSCAR CEREMONIES (Now using Festival tables)
  # ========================================

  @doc """
  Returns the list of Oscar ceremonies from festival tables.
  """
  def list_oscar_ceremonies do
    oscar_org = Festivals.get_or_create_oscar_organization()

    if oscar_org && oscar_org.id do
      Festivals.list_ceremonies(oscar_org.id)
    else
      []
    end
  end

  @doc """
  Gets a single Oscar ceremony by year from festival tables.
  """
  def get_oscar_ceremony_by_year(year) do
    oscar_org = Festivals.get_or_create_oscar_organization()

    if oscar_org && oscar_org.id do
      Festivals.get_ceremony_by_year(oscar_org.id, year)
    else
      nil
    end
  end

  @doc """
  Import Oscar data for a specific year.
  This fetches the ceremony, enhances with IMDb IDs, and imports all movies.

  ## Options
    * `:create_movies` - whether to create new movie records (default: true)
    * `:create_partial` - whether to create partial records for movies not in TMDb (default: false)
    * `:queue_enrichment` - whether to queue OMDb enrichment jobs (default: true)

  ## Examples

      iex> Cinegraph.Cultural.import_oscar_year(2024)
      {:ok, %{movies_created: 45, movies_updated: 78, ...}}
      
  """
  def import_oscar_year(year, options \\ []) do
    Logger.info("Starting Oscar import for year #{year}")

    with {:ok, ceremony} <- fetch_or_create_ceremony(year) do
      # Queue the discovery worker to process the ceremony
      job_args = %{
        "ceremony_id" => ceremony.id,
        "options" => Enum.into(options, %{})
      }

      # Use FestivalDiscoveryWorker (fuzzy matching to be ported from OscarDiscoveryWorker)
      case Cinegraph.Workers.FestivalDiscoveryWorker.new(job_args) |> Oban.insert() do
        {:ok, job} ->
          {:ok,
           %{
             ceremony_id: ceremony.id,
             year: year,
             job_id: job.id,
             status: :queued
           }}

        {:error, reason} ->
          Logger.error("Failed to queue Oscar discovery for year #{year}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, reason} ->
        Logger.error("Failed to prepare Oscar year #{year}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Import Oscar data for a range of years.

  By default, this queues jobs for parallel processing. Use `async: false` for sequential processing.

  ## Options
    * `:async` - whether to use job queue (default: true)
    * All other options are passed to `import_oscar_year/2`

  ## Examples

      # Queue jobs for parallel processing (default)
      iex> Cinegraph.Cultural.import_oscar_years(2020..2024)
      {:ok, %{years: 2020..2024, job_count: 5, status: :queued}}
      
      # Sequential processing
      iex> Cinegraph.Cultural.import_oscar_years(2020..2024, async: false)
      %{2020 => {:ok, %{...}}, 2021 => {:ok, %{...}}, ...}
      
  """
  def import_oscar_years(start_year..end_year//_, options \\ []) do
    {async, import_options} = Keyword.pop(options, :async, true)

    if async do
      # Queue jobs for parallel processing
      years = start_year..end_year |> Enum.to_list()

      jobs =
        Enum.map(years, fn year ->
          %{year: year, options: Enum.into(import_options, %{})}
          |> Cinegraph.Workers.OscarImportWorker.new()
        end)

      # Insert jobs individually and collect results
      results = Enum.map(jobs, &Oban.insert/1)

      {successes, failures} =
        Enum.split_with(results, fn
          {:ok, _} -> true
          {:error, _} -> false
        end)

      successful_jobs = length(successes)

      if successful_jobs == length(years) do
        {:ok,
         %{
           years: start_year..end_year,
           job_count: successful_jobs,
           status: :queued
         }}
      else
        failed_years =
          failures
          |> Enum.zip(years)
          |> Enum.filter(fn
            {{:error, _}, _} -> true
            _ -> false
          end)
          |> Enum.map(fn {_, year} -> year end)

        {:error, "Failed to queue jobs for years: #{inspect(failed_years)}"}
      end
    else
      # Sequential processing (original behavior)
      start_year..end_year
      |> Enum.map(fn year ->
        {year, import_oscar_year(year, import_options)}
      end)
      |> Enum.into(%{})
    end
  end

  @doc """
  Import all available Oscar years (2016-2024).
  Note: Oscars.org has data from 2016 onwards in the current format.

  ## Examples

      iex> Cinegraph.Cultural.import_all_oscar_years()
      %{2016 => {:ok, %{...}}, 2017 => {:ok, %{...}}, ...}
      
  """
  def import_all_oscar_years(options \\ []) do
    # Oscars.org has data from 2016 onwards in the current format
    import_oscar_years(2016..2024, options)
  end

  defp fetch_or_create_ceremony(year) do
    # Get the Oscar organization first
    oscar_org = Festivals.get_or_create_oscar_organization()

    # Use the new festival_ceremonies table with organization_id
    case Festivals.get_ceremony_by_year(oscar_org.id, year) do
      nil ->
        Logger.info("Fetching Oscar ceremony data for #{year}")

        case OscarScraper.fetch_ceremony(year) do
          {:ok, data} ->
            attrs = %{
              organization_id: oscar_org.id,
              year: year,
              ceremony_number: calculate_ceremony_number(year),
              data: data,
              data_source: "official_website",
              source_url: "https://www.oscars.org/oscars/ceremonies/#{year}",
              scraped_at: DateTime.utc_now(),
              source_metadata: %{
                "scraper" => "OscarScraper",
                "version" => "1.0",
                "import_status" => "pending",
                "scraped_at" => DateTime.utc_now() |> DateTime.to_iso8601()
              }
            }

            Festivals.upsert_ceremony(attrs)

          {:error, reason} ->
            {:error, reason}
        end

      ceremony ->
        {:ok, ceremony}
    end
  end

  defp calculate_ceremony_number(year) do
    # First ceremony was in 1929 for 1927-1928 films
    year - 1927
  end

  @doc """
  Get the status of Oscar import jobs.

  ## Examples

      iex> Cinegraph.Cultural.get_oscar_import_status()
      %{
        running_jobs: 2,
        queued_jobs: 3,
        completed_jobs: 5,
        failed_jobs: 0
      }
      
  """
  def get_oscar_import_status do
    import Ecto.Query

    # Count jobs by state
    job_counts =
      Oban.Job
      |> where([j], j.worker == "Cinegraph.Workers.OscarImportWorker")
      |> group_by([j], j.state)
      |> select([j], {j.state, count(j.id)})
      |> Repo.replica().all()
      |> Enum.into(%{})

    %{
      running_jobs: Map.get(job_counts, "executing", 0),
      queued_jobs: Map.get(job_counts, "available", 0) + Map.get(job_counts, "scheduled", 0),
      completed_jobs: Map.get(job_counts, "completed", 0),
      failed_jobs: Map.get(job_counts, "retryable", 0) + Map.get(job_counts, "discarded", 0)
    }
  end

  # ========================================
  # VENICE FILM FESTIVAL CEREMONIES
  # ========================================

  @doc """
  Returns the list of Venice Film Festival ceremonies from festival tables.
  """
  def list_venice_ceremonies do
    venice_org = get_or_create_venice_organization()

    if venice_org && venice_org.id do
      Festivals.list_ceremonies(venice_org.id)
    else
      []
    end
  end

  @doc """
  Gets a single Venice ceremony by year from festival tables.
  """
  def get_venice_ceremony_by_year(year) do
    venice_org = get_or_create_venice_organization()

    if venice_org && venice_org.id do
      Festivals.get_ceremony_by_year(venice_org.id, year)
    else
      nil
    end
  end

  @doc """
  Import Venice Film Festival data for a specific year.

  ## Options
    * `:create_movies` - whether to create new movie records (default: true)
    * `:queue_enrichment` - whether to queue TMDb enrichment jobs (default: true)

  ## Examples

      iex> Cinegraph.Cultural.import_venice_year(2024)
      {:ok, %{ceremony_id: 123, year: 2024, job_id: 456, status: :queued}}
      
  """
  def import_venice_year(year, options \\ []) do
    Logger.info("Starting Venice Film Festival import for year #{year}")

    job_args = %{
      "festival" => "venice",
      "year" => year,
      "options" => Enum.into(options, %{})
    }

    # Use unique args to prevent duplicate jobs for the same year
    case Cinegraph.Workers.UnifiedFestivalWorker.new(job_args,
           unique: [period: 60, fields: [:args, :worker]]
         )
         |> Oban.insert() do
      {:ok, job} ->
        {:ok,
         %{
           year: year,
           job_id: job.id,
           status: :queued,
           worker: "UnifiedFestivalWorker"
         }}

      {:error, %Ecto.Changeset{errors: [unique: {"has already been taken", _}]}} ->
        Logger.info("Venice import for year #{year} already queued or running")

        {:ok,
         %{
           year: year,
           status: :already_queued,
           worker: "UnifiedFestivalWorker"
         }}

      {:error, reason} ->
        Logger.error("Failed to queue Venice import for year #{year}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Import Venice Film Festival data for a range of years.

  ## Options
    * `:max_concurrency` - number of concurrent requests (default: 3)
    * All other options are passed to the worker

  ## Examples

      iex> Cinegraph.Cultural.import_venice_years(2020..2024)
      {:ok, %{years: 2020..2024, job_id: 123, status: :queued}}
      
  """
  def import_venice_years(start_year..end_year//_, options \\ []) do
    years = start_year..end_year |> Enum.to_list()

    job_args = %{
      "festival" => "venice",
      "years" => years,
      "options" => Enum.into(options, %{})
    }

    Logger.info(
      "Starting Venice Film Festival import for #{length(years)} years: #{inspect(years)}"
    )

    # Use unique args to prevent duplicate jobs for the same years
    case Cinegraph.Workers.UnifiedFestivalWorker.new(job_args,
           unique: [period: 60, fields: [:args, :worker]]
         )
         |> Oban.insert() do
      {:ok, job} ->
        {:ok,
         %{
           years: start_year..end_year,
           year_count: length(years),
           job_id: job.id,
           status: :queued,
           worker: "UnifiedFestivalWorker"
         }}

      {:error, %Ecto.Changeset{errors: [unique: {"has already been taken", _}]}} ->
        Logger.info("Venice import for years #{inspect(years)} already queued or running")

        {:ok,
         %{
           years: start_year..end_year,
           year_count: length(years),
           status: :already_queued,
           worker: "UnifiedFestivalWorker"
         }}

      {:error, reason} ->
        Logger.error(
          "Failed to queue Venice import for years #{inspect(years)}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Gets Venice Film Festival nominations for a movie from the festival tables.
  """
  def get_movie_venice_nominations(movie_id) do
    # Get the Venice organization
    venice_org = get_or_create_venice_organization()

    if venice_org && venice_org.id do
      from(nomination in Cinegraph.Festivals.FestivalNomination,
        join: ceremony in Cinegraph.Festivals.FestivalCeremony,
        on: nomination.ceremony_id == ceremony.id,
        join: category in Cinegraph.Festivals.FestivalCategory,
        on: nomination.category_id == category.id,
        left_join: person in Cinegraph.Movies.Person,
        on: nomination.person_id == person.id,
        where: nomination.movie_id == ^movie_id and ceremony.organization_id == ^venice_org.id,
        order_by: [desc: ceremony.year, asc: category.name],
        select: %{
          ceremony_year: ceremony.year,
          category_name: category.name,
          category_type: category.category_type,
          tracks_person: category.tracks_person,
          won: nomination.won,
          details: nomination.details,
          person: person
        }
      )
      |> Repo.replica().all()
    else
      []
    end
  end

  @doc """
  Get the status of Venice Film Festival import jobs.
  """
  def get_venice_import_status do
    import Ecto.Query

    # Count jobs by state
    job_counts =
      Oban.Job
      |> where([j], j.worker == "Cinegraph.Workers.UnifiedFestivalWorker")
      |> where([j], fragment("? ->> 'festival' = ?", j.args, "venice"))
      |> group_by([j], j.state)
      |> select([j], {j.state, count(j.id)})
      |> Repo.replica().all()
      |> Enum.into(%{})

    %{
      running_jobs: Map.get(job_counts, "executing", 0),
      queued_jobs: Map.get(job_counts, "available", 0) + Map.get(job_counts, "scheduled", 0),
      completed_jobs: Map.get(job_counts, "completed", 0),
      failed_jobs: Map.get(job_counts, "retryable", 0) + Map.get(job_counts, "discarded", 0)
    }
  end

  defp get_or_create_venice_organization do
    # Try to get existing Venice organization first
    case Festivals.get_organization_by_abbreviation("VIFF") do
      nil ->
        # Create new using the same pattern as Oscar
        attrs = %{
          name: "Venice International Film Festival",
          abbreviation: "VIFF",
          country: "Italy",
          founded_year: 1932,
          website: "https://www.labiennale.org/en/cinema"
        }

        %Festivals.FestivalOrganization{}
        |> Festivals.FestivalOrganization.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, org} ->
            org

          {:error, _changeset} ->
            # Race condition - try to get again
            Repo.get_by!(Festivals.FestivalOrganization, abbreviation: "VIFF")
        end

      existing_org ->
        existing_org
    end
  end

  # ========================================
  # UNIFIED FESTIVAL IMPORTS
  # ========================================

  @doc """
  Import festival data for a specific festival and year.

  ## Parameters
    * festival - One of: "cannes", "bafta", "berlin", "venice"
    * year - The festival year
    * options - Import options
    
  ## Examples

      iex> Cinegraph.Cultural.import_festival("cannes", 2024)
      {:ok, %{festival: "cannes", year: 2024, job_id: 123, status: :queued}}
      
  """
  def import_festival(festival, year, options \\ []) when is_binary(festival) do
    Logger.info("Starting #{festival} import for year #{year}")

    job_args = %{
      "festival" => festival,
      "year" => year,
      "options" => Enum.into(options, %{})
    }

    case Cinegraph.Workers.UnifiedFestivalWorker.new(job_args) |> Oban.insert() do
      {:ok, job} ->
        {:ok,
         %{
           festival: festival,
           year: year,
           job_id: job.id,
           status: :queued,
           worker: "UnifiedFestivalWorker"
         }}

      {:error, reason} ->
        Logger.error("Failed to queue #{festival} import for year #{year}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Import all active festivals/ceremonies for a specific year.
  Queries the database for all active festival events rather than using a hardcoded list.

  ## Examples

      iex> Cinegraph.Cultural.import_all_festivals_for_year(2024)
      {:ok, %{year: 2024, festivals: [...], jobs: 11}}

  """
  def import_all_festivals_for_year(year, options \\ []) do
    festivals =
      Events.list_active_events()
      |> Enum.map(& &1.source_key)

    jobs =
      Enum.map(festivals, fn festival ->
        job_args = %{
          "festival" => festival,
          "year" => year,
          "options" => Enum.into(options, %{})
        }

        Cinegraph.Workers.UnifiedFestivalWorker.new(job_args)
      end)

    results = Enum.map(jobs, &Oban.insert/1)

    successful =
      Enum.count(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    if successful == length(festivals) do
      {:ok,
       %{
         year: year,
         festivals: festivals,
         jobs: successful,
         status: :queued
       }}
    else
      failed =
        festivals
        |> Enum.zip(results)
        |> Enum.filter(fn {_, result} ->
          case result do
            {:ok, _} -> false
            _ -> true
          end
        end)
        |> Enum.map(fn {festival, _} -> festival end)

      {:error, "Failed to queue imports for: #{inspect(failed)}"}
    end
  end

  @doc """
  Get the status of festival import jobs.

  ## Parameters
    * festival - Optional festival filter (e.g., "cannes")
    
  ## Examples

      iex> Cinegraph.Cultural.get_festival_import_status()
      %{running_jobs: 2, queued_jobs: 3, completed_jobs: 5, failed_jobs: 0}
      
      iex> Cinegraph.Cultural.get_festival_import_status("cannes")
      %{running_jobs: 1, queued_jobs: 0, completed_jobs: 2, failed_jobs: 0}
      
  """
  def get_festival_import_status(festival \\ nil) do
    import Ecto.Query

    query =
      Oban.Job
      |> where([j], j.worker == "Cinegraph.Workers.UnifiedFestivalWorker")

    query =
      if festival do
        where(query, [j], fragment("? ->> 'festival' = ?", j.args, ^festival))
      else
        query
      end

    job_counts =
      query
      |> group_by([j], j.state)
      |> select([j], {j.state, count(j.id)})
      |> Repo.replica().all()
      |> Enum.into(%{})

    %{
      running_jobs: Map.get(job_counts, "executing", 0),
      queued_jobs: Map.get(job_counts, "available", 0) + Map.get(job_counts, "scheduled", 0),
      completed_jobs: Map.get(job_counts, "completed", 0),
      failed_jobs: Map.get(job_counts, "retryable", 0) + Map.get(job_counts, "discarded", 0)
    }
  end

  # ========================================
  # SEED DATA FUNCTIONS
  # ========================================

  @doc """
  Seeds initial cultural authorities.
  """
  def seed_authorities do
    authorities = [
      %{
        name: "Academy of Motion Picture Arts and Sciences",
        authority_type: "award",
        trust_score: 9.5,
        description: "The organization behind the Academy Awards (Oscars)",
        website: "https://www.oscars.org",
        active: true
      },
      %{
        name: "Cannes Film Festival",
        authority_type: "award",
        trust_score: 9.0,
        description: "Prestigious international film festival",
        website: "https://www.festival-cannes.com",
        active: true
      },
      %{
        name: "Criterion Collection",
        authority_type: "collection",
        trust_score: 8.8,
        description: "Curated collection of important classic and contemporary films",
        website: "https://www.criterion.com",
        active: true
      },
      %{
        name: "British Film Institute",
        authority_type: "critic",
        trust_score: 8.5,
        description: "UK's lead organisation for film, television and the moving image",
        website: "https://www.bfi.org.uk",
        active: true
      }
    ]

    Enum.each(authorities, fn attrs ->
      case get_authority_by_name(attrs.name) do
        nil -> create_authority(attrs)
        _existing -> :ok
      end
    end)
  end

  # ========================================
  # PRIVATE HELPER FUNCTIONS
  # ========================================

  defp get_movie_cultural_data(movie_id) do
    from(movie in Cinegraph.Movies.Movie,
      left_join: list_items in assoc(movie, :movie_list_items),
      left_join: lists in assoc(list_items, :list),
      left_join: authorities in assoc(lists, :authority),
      where: movie.id == ^movie_id,
      preload: [movie_list_items: {list_items, list: {lists, authority: authorities}}]
    )
    |> Repo.replica().one()
  end

  defp calculate_authority_presence(movie_data) do
    if movie_data && movie_data.movie_list_items do
      authorities =
        movie_data.movie_list_items
        |> Enum.map(& &1.list.authority)
        |> Enum.uniq_by(& &1.id)

      # Weight by authority trust scores
      total_weight =
        authorities
        |> Enum.map(& &1.trust_score)
        |> Enum.sum()

      # Normalize to 0-1 scale (trust_score is 0-10)
      min(total_weight / 100.0, 1.0)
    else
      0.0
    end
  end

  defp calculate_list_appearances(movie_data) do
    if movie_data && movie_data.movie_list_items do
      count = length(movie_data.movie_list_items)
      # Logarithmic scale - more lists = higher score but with diminishing returns
      # Max around 50 list appearances
      :math.log(count + 1) / :math.log(50)
    else
      0.0
    end
  end

  defp calculate_award_recognition(movie_data) do
    if movie_data && movie_data.movie_list_items do
      award_items =
        movie_data.movie_list_items
        |> Enum.filter(&(&1.award_result in ["winner", "nominee"]))

      winners = Enum.count(award_items, &(&1.award_result == "winner"))
      nominees = Enum.count(award_items, &(&1.award_result == "nominee"))

      # Winners worth more than nominees
      score = winners * 1.0 + nominees * 0.5

      # Normalize
      min(score / 10.0, 1.0)
    else
      0.0
    end
  end

  defp calculate_cultural_impact(movie_data) do
    if movie_data && movie_data.movie_list_items do
      # Count of appearances in lists as a proxy for cultural impact
      count = length(movie_data.movie_list_items)
      # Normalize to 0-1 scale with diminishing returns
      min(count / 20.0, 1.0)
    else
      0.0
    end
  end
end
