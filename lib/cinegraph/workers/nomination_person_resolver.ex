defmodule Cinegraph.Workers.NominationPersonResolver do
  @moduledoc """
  Re-runs the festival person-resolver against an existing nomination
  whose `person_id IS NULL`. Used to drain the backlog surfaced by
  `Cinegraph.Health.Drift.People.person_required_nomination_missing_person/0`
  (#730 Phase 1a).

  Wraps `FestivalDiscoveryWorker.resolve_for_nomination/1` and persists the
  resolved `person_id`. Runs on the `:maintenance` queue (2-concurrent) so a
  backfill of thousands of jobs doesn't dogpile the `:tmdb` rate limit when
  the resolver falls through to its TMDb-search phase.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [fields: [:args], keys: [:nomination_id], period: 3600]

  alias Cinegraph.Festivals.FestivalNomination
  alias Cinegraph.Repo
  alias Cinegraph.Workers.FestivalDiscoveryWorker

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"nomination_id" => nomination_id}}) do
    case Repo.get(FestivalNomination, nomination_id) do
      nil ->
        {:cancel, :nomination_not_found}

      %FestivalNomination{person_id: pid} when not is_nil(pid) ->
        {:ok, %{action: :already_resolved, person_id: pid}}

      nom ->
        nom = Repo.preload(nom, [:category, :movie])

        case FestivalDiscoveryWorker.resolve_for_nomination(nom) do
          nil ->
            Logger.info("NominationPersonResolver: no match for nom #{nom.id}")
            {:ok, %{action: :no_match}}

          person_id when is_integer(person_id) ->
            nom
            |> FestivalNomination.changeset(%{person_id: person_id})
            |> Repo.update()
            |> case do
              {:ok, _} ->
                Logger.info(
                  "NominationPersonResolver: resolved nom #{nom.id} → person #{person_id}"
                )

                {:ok, %{action: :resolved, person_id: person_id}}

              {:error, changeset} ->
                Logger.error(
                  "NominationPersonResolver: persist failed for nom #{nom.id}: " <>
                    inspect(changeset.errors)
                )

                {:error, changeset}
            end
        end
    end
  end
end
