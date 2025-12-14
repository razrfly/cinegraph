defmodule Cinegraph.Workers.UnifiedFestivalWorker do
  @moduledoc """
  Unified worker for importing various film festivals and awards from IMDb.
  Supports Cannes, BAFTA, Berlin, and Venice.
  """

  use Oban.Worker,
    queue: :festival_import,
    max_attempts: 3,
    unique: [period: 60, fields: [:args], keys: [:festival, :year]]

  require Logger
  alias Cinegraph.Scrapers.UnifiedFestivalScraper
  alias Cinegraph.Festivals
  alias Cinegraph.Events
  alias Cinegraph.Workers.FestivalDiscoveryWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"festival" => festival, "year" => year}}) do
    Logger.info("Starting #{festival} import for year #{year}")

    with {:ok, festival_config} <- get_festival_config(festival),
         {:ok, organization} <- get_or_create_organization(festival_config),
         {:ok, festival_data} <- UnifiedFestivalScraper.fetch_festival_data(festival, year),
         {:ok, ceremony} <- create_or_update_ceremony(organization, year, festival_data),
         {:ok, _discovery_job} <- queue_festival_discovery_job(ceremony) do
      Logger.info("Successfully imported #{festival} #{year} ceremony and queued discovery job")
      :ok
    else
      # HTTP 404 means the page doesn't exist on IMDb - don't retry, just cancel
      {:error, "HTTP 404"} ->
        Logger.warning(
          "#{festival} #{year}: Page not found on IMDb (404) - year may not have data. Cancelling job."
        )

        # Update import status to reflect no data available
        update_import_status_no_data(festival, year)
        {:cancel, "HTTP 404 - page does not exist on IMDb"}

      # HTTP 403 is also permanent - IMDb blocked access
      {:error, "HTTP 403"} ->
        Logger.warning("#{festival} #{year}: Access forbidden (403) - cancelling job.")
        {:cancel, "HTTP 403 - access forbidden"}

      {:error, reason} ->
        Logger.error("Failed to import #{festival} #{year}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Handle multiple years import
  def perform(%Oban.Job{args: %{"festival" => festival, "years" => years} = args})
      when is_list(years) do
    Logger.info("Starting #{festival} import for #{length(years)} years: #{inspect(years)}")

    max_concurrency = Map.get(args, "max_concurrency", 3)

    # Process years with controlled concurrency
    results =
      years
      |> Task.async_stream(
        fn year ->
          {year, perform(%Oban.Job{args: %{"festival" => festival, "year" => year}})}
        end,
        max_concurrency: max_concurrency,
        timeout: 120_000
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {nil, {:error, {:timeout, reason}}}
      end)
      |> Map.new()

    failed_years =
      results
      |> Enum.filter(fn {_year, result} ->
        case result do
          :ok -> false
          _ -> true
        end
      end)
      |> Enum.map(fn {year, _} -> year end)

    if length(failed_years) == 0 do
      Logger.info("Successfully imported all #{length(years)} years for #{festival}")
      :ok
    else
      Logger.error(
        "Failed to import #{length(failed_years)} years for #{festival}: #{inspect(failed_years)}"
      )

      {:error, "Failed years: #{inspect(failed_years)}"}
    end
  end

  defp get_festival_config(festival_key) do
    case UnifiedFestivalScraper.get_festival_config(festival_key) do
      nil -> {:error, "Unknown festival: #{festival_key}"}
      config -> {:ok, config}
    end
  end

  defp get_or_create_organization(festival_config) do
    case Festivals.get_organization_by_abbreviation(festival_config.abbreviation) do
      nil ->
        attrs = %{
          name: festival_config.name,
          abbreviation: festival_config.abbreviation,
          country: festival_config.country,
          founded_year: festival_config.founded_year,
          website: festival_config.website
        }

        case Festivals.create_organization(attrs) do
          {:ok, org} ->
            {:ok, org}

          {:error, changeset} ->
            # Race condition - try to get again
            case Festivals.get_organization_by_abbreviation(festival_config.abbreviation) do
              nil -> {:error, changeset}
              org -> {:ok, org}
            end
        end

      org ->
        {:ok, org}
    end
  end

  defp create_or_update_ceremony(organization, year, festival_data) do
    # Get the event configuration from database to build proper source URL
    event_id = get_event_id_from_database(organization)

    # Build source URL or use a fallback for missing event IDs
    source_url =
      case build_source_url(event_id, year) do
        {:ok, url} ->
          url

        {:error, :missing_event_id} ->
          Logger.warning(
            "Missing IMDb event ID for #{organization.abbreviation}, using fallback URL"
          )

          nil
      end

    attrs = %{
      organization_id: organization.id,
      year: year,
      name: "#{year} #{organization.name}",
      data: festival_data,
      data_source: "imdb",
      source_url: source_url,
      scraped_at: DateTime.utc_now(),
      source_metadata: %{
        "scraper" => "UnifiedFestivalScraper",
        "version" => "1.0",
        "parser" => festival_data[:parser] || "unknown",
        "import_status" => "pending",
        "scraped_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }

    Festivals.upsert_ceremony(attrs)
  end

  defp get_event_id_from_database(organization) do
    # Look up the festival event in the database by organization abbreviation
    case Events.list_active_events() do
      events when is_list(events) ->
        event =
          Enum.find(events, fn e ->
            e.abbreviation == organization.abbreviation
          end)

        if event && event.source_config do
          # Get the IMDb event ID from the database configuration
          event.source_config["event_id"] || event.source_config["imdb_event_id"]
        else
          Logger.warning(
            "No event configuration found for organization: #{organization.abbreviation}"
          )

          nil
        end

      _ ->
        nil
    end
  end

  defp build_source_url(nil, _year), do: {:error, :missing_event_id}

  defp build_source_url(event_id, year),
    do: {:ok, "https://www.imdb.com/event/#{event_id}/#{year}/1/"}

  defp queue_festival_discovery_job(ceremony) do
    job_args = %{
      "ceremony_id" => ceremony.id,
      "source" => "unified_festival_worker"
    }

    case FestivalDiscoveryWorker.new(job_args) |> Oban.insert() do
      {:ok, job} ->
        Logger.info("Queued FestivalDiscoveryWorker job #{job.id} for ceremony #{ceremony.id}")
        {:ok, job}

      {:error, reason} ->
        Logger.error(
          "Failed to queue FestivalDiscoveryWorker for ceremony #{ceremony.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # Create an empty ceremony to track the 404 status for this year
  defp update_import_status_no_data(festival_key, year) do
    with {:ok, festival_config} <- get_festival_config(festival_key),
         {:ok, organization} <- get_or_create_organization(festival_config) do
      # Create a ceremony entry with "no_data" status so it shows up in the dashboard
      attrs = %{
        organization_id: organization.id,
        year: year,
        name: "#{year} #{organization.name}",
        data: %{awards: [], nominations: []},
        data_source: "imdb",
        source_url: nil,
        scraped_at: DateTime.utc_now(),
        source_metadata: %{
          "scraper" => "UnifiedFestivalScraper",
          "version" => "1.0",
          "parser" => "none",
          "import_status" => "no_data",
          "error" => "HTTP 404 - page not found on IMDb",
          "note" => "Year exists in IMDb history but has no actual data page",
          "scraped_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      }

      case Festivals.upsert_ceremony(attrs) do
        {:ok, _ceremony} ->
          Logger.info(
            "Created no_data ceremony entry for #{organization.abbreviation} #{year}"
          )

        {:error, reason} ->
          Logger.warning(
            "Failed to create no_data ceremony for #{organization.abbreviation} #{year}: #{inspect(reason)}"
          )
      end
    else
      {:error, reason} ->
        Logger.warning("Cannot update import status for #{festival_key} #{year}: #{inspect(reason)}")
    end
  end
end
