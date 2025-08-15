defmodule Cinegraph.Workers.FestivalPersonInferenceWorker do
  @moduledoc """
  Worker to run person inference for festival nominations after discovery completes.

  This worker:
  1. Runs after FestivalDiscoveryWorker completes
  2. Infers person IDs for director nominations
  3. Only processes non-Oscar festivals (Oscars have person names in data)

  Issue #250: Ensures person linkages are created automatically after import.
  """

  use Oban.Worker,
    queue: :festival_import,
    max_attempts: 3,
    unique: [fields: [:args], keys: [:ceremony_id], period: 300]

  alias Cinegraph.People.FestivalPersonInferrer
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"ceremony_id" => ceremony_id, "abbr" => abbr, "year" => year}}) do
    Logger.metadata(ceremony_id: ceremony_id, organization: abbr, year: year)
    Logger.info("Running person inference for #{abbr} #{year} (ceremony ##{ceremony_id})")

    # Skip AMPAS/Oscar ceremonies as they already have person names in data
    if abbr == "AMPAS" do
      Logger.info("Skipping person inference for Oscars (AMPAS) ceremony ##{ceremony_id}")
      :ok
    else
      try do
        {microseconds, result} =
          :timer.tc(fn ->
            FestivalPersonInferrer.infer_all_director_nominations()
          end)

        milliseconds = div(microseconds, 1000)

        case result do
          %{success: success, skipped: skipped, failed: failed, total: total} ->
            Logger.info(
              "Person inference completed for #{abbr} #{year} in #{milliseconds}ms: " <>
                "#{success}/#{total} linked, #{skipped} skipped, #{failed} failed"
            )

            :ok

          other ->
            Logger.warning(
              "Person inference returned unexpected result for #{abbr} #{year}: #{inspect(other)}"
            )

            :ok
        end
      rescue
        error ->
          Logger.error(
            "Person inference failed for #{abbr} #{year}: " <>
              Exception.format(:error, error, __STACKTRACE__)
          )

          {:error, :person_inference_failed}
      end
    end
  end
end
