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
  alias Cinegraph.Workers.{TMDbDetailsWorker, FestivalDiscoveryWorker}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"festival" => festival, "year" => year} = args}) do
    Logger.info("Starting #{festival} import for year #{year}")

    with {:ok, festival_config} <- get_festival_config(festival),
         {:ok, organization} <- get_or_create_organization(festival_config),
         {:ok, festival_data} <- UnifiedFestivalScraper.fetch_festival_data(festival, year),
         {:ok, ceremony} <- create_or_update_ceremony(organization, year, festival_data),
         {:ok, _discovery_job} <- queue_festival_discovery_job(ceremony) do
      Logger.info("Successfully imported #{festival} #{year} ceremony and queued discovery job")
      :ok
    else
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
    attrs = %{
      organization_id: organization.id,
      year: year,
      name: "#{year} #{organization.name}",
      data: festival_data,
      data_source: "imdb",
      source_url: "https://www.imdb.com/event/#{get_event_id(organization)}/#{year}/1/",
      scraped_at: DateTime.utc_now(),
      source_metadata: %{
        "scraper" => "UnifiedFestivalScraper",
        "version" => "1.0",
        "parser" => festival_data[:parser] || "unknown"
      }
    }

    Festivals.upsert_ceremony(attrs)
  end

  defp get_event_id(organization) do
    # Map organization back to IMDb event ID
    case organization.abbreviation do
      # Cannes
      "CFF" -> "ev0000147"
      # BAFTA
      "BAFTA" -> "ev0000123"
      # Berlin
      "BIFF" -> "ev0000091"
      # Venice
      "VIFF" -> "ev0000681"
      _ -> nil
    end
  end

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
end
