defmodule Cinegraph.Workers.TMDbCompanyMetadataWorker do
  @moduledoc """
  Refreshes TMDb details/images metadata for a production company.
  """

  use Oban.Worker,
    queue: :tmdb,
    max_attempts: 3,
    unique: [fields: [:args], keys: [:company_id], period: 86_400]

  alias Cinegraph.Movies

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"company_id" => company_id}}) do
    case Movies.refresh_production_company_metadata(company_id) do
      {:ok, company} ->
        Logger.info("Refreshed TMDb company metadata for #{company.name} (#{company.id})")
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to refresh TMDb company metadata for company #{company_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
