defmodule Cinegraph.Workers.PersonTmdbRefreshWorker do
  @moduledoc """
  Re-fetches a `people` row from TMDb and updates `profile_path`,
  `biography`, `known_for_department`, `popularity`, etc.

  Enqueued by the `/admin/health` People drawer (#723) as a remediation
  for missing-data drift. Wraps `Cinegraph.Movies.fetch_and_update_person/1`.

  Uniqueness is keyed on `:person_id` for 1 hour to avoid stampedes when
  the same person is queued multiple times.
  """

  use Oban.Worker,
    queue: :tmdb,
    max_attempts: 3,
    unique: [fields: [:args], keys: [:person_id], period: 3600]

  alias Cinegraph.{Freshness, Movies, People, Repo}
  alias Cinegraph.Movies.Person

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"person_id" => person_id}}) do
    # Route all Repo.replica() calls through the dedicated worker pool
    # so this job does not compete with web requests for Repo.Replica connections. (#1007)
    # Note: the Repo.get(Person, person_id) below intentionally uses the primary (not replica)
    # to avoid replica-lag false negatives — that call is unaffected by this routing key.
    Cinegraph.Repo.route_to_worker()
    Logger.info("PersonTmdbRefreshWorker refreshing person #{person_id}")

    # Read from the *primary* repo here. `People.get_person/1` hits the read
    # replica, which can briefly miss freshly-inserted rows due to replica
    # lag — that would falsely cancel the job. Reading from the primary
    # avoids the false negative.
    case Repo.get(Person, person_id) do
      nil ->
        Logger.warning("PersonTmdbRefreshWorker: person #{person_id} not found, skipping")
        # Don't retry — the row is gone
        {:cancel, :person_not_found}

      person ->
        # #1096 Phase B: age-tier by the person's most recent credit. This is the
        # tracking that lets the biography backlog reach a terminal state instead of
        # churning (today people have 0 fetch_attempt rows) — Phase C consumes it.
        base_date = People.latest_credit_date(person.id)

        case Movies.fetch_and_update_person(person.tmdb_id) do
          {:ok, updated} ->
            Logger.info("PersonTmdbRefreshWorker refreshed person #{person.id}")
            Freshness.touch("person", person.id, "tmdb_person", :ok, base_date: base_date)
            {:ok, updated}

          {:error, reason} ->
            Logger.error(
              "PersonTmdbRefreshWorker failed for person #{person.id}: #{inspect(reason)}"
            )

            Freshness.touch("person", person.id, "tmdb_person", :error,
              base_date: base_date,
              error_reason: inspect(reason)
            )

            {:error, reason}
        end
    end
  end
end
