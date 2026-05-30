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
  def perform(%Oban.Job{args: %{"company_id" => company_id}}) when is_integer(company_id) do
    # Route all Repo.replica() calls through the dedicated worker pool
    # so this job does not compete with web requests for Repo.Replica connections. (#1007)
    Process.put(:cinegraph_job_repo, Cinegraph.Repo.Worker)
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

  def perform(%Oban.Job{args: %{"company_id" => company_id}} = job) when is_binary(company_id) do
    case Integer.parse(String.trim(company_id)) do
      {id, ""} -> perform(%{job | args: Map.put(job.args, "company_id", id)})
      _ -> {:discard, :invalid_company_id}
    end
  end

  def perform(%Oban.Job{args: _args}), do: {:discard, :invalid_args}
end
