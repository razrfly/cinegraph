defmodule Cinegraph.Workers.TMDbDiscoveryWorker do
  @moduledoc """
  Simplified discovery worker that uses state tracking instead of progress records.
  """

  use Oban.Worker,
    queue: :tmdb,
    max_attempts: 3,
    unique: [period: 60]

  alias Cinegraph.Imports.TMDbImporter
  alias Cinegraph.Services.TMDb.Client
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"page" => page} = args}) do
    Logger.info("Processing discovery page #{page}")

    # Build query params
    params = build_query_params(page, args)

    # Fetch movies from TMDb
    case Client.get("/discover/movie", params) do
      {:ok, %{"results" => results, "total_pages" => total_pages}} ->
        Logger.info("Found #{length(results)} movies on page #{page}/#{total_pages}")

        # Process this page (filters duplicates and queues detail jobs)
        case TMDbImporter.process_discovery_page(page, results) do
          {:ok, queued_count} ->
            Logger.info("Queued #{queued_count} new movies for import")
            :ok

          error ->
            Logger.error("Failed to process discovery page: #{inspect(error)}")
            error
        end

      {:error, reason} ->
        Logger.error("Failed to fetch page #{page}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_query_params(page, args) do
    # Start with page number
    params = %{"page" => page}

    # Add any additional filters from args
    # Drop our internal tracking fields, keep TMDb API params like primary_release_year
    args
    |> Map.drop(["page", "import_type", "import_progress_id", "year"])
    |> Enum.into(params)
  end
end
