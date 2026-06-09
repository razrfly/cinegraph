defmodule Cinegraph.Freshness do
  @moduledoc """
  The uniform freshness API over the `data_refreshes` ledger (#1096 Phase B /
  #1010 substrate). One vocabulary for **every** external source:

    * `touch/5` — every fetch worker calls this after an attempt (success/empty/error).
    * `stale?/3` — is this entity×source due for a refresh?
    * `due/2`   — floor sweepers select stale entity ids (consumed in #1096 Phase C).

  Freshness *metadata only* lives here; the actual values stay in
  `external_metrics`, `movies.omdb_data`, etc. `stale_after` is computed by the
  per-`(entity_type, source)` strategy in `Cinegraph.Freshness.Policy`.

  Status vocabulary (#1010 §6): `ok` (fetched), `empty` (source had nothing —
  subsumes the OMDb `fetch_attempt` cooldown), `error` (failed; backed-off retry),
  `ineligible` (precondition fails or too many errors — never due), `pending`.
  """
  import Ecto.Query

  alias Cinegraph.Freshness.{DataRefresh, Policy}
  alias Cinegraph.Repo

  @doc """
  Record the outcome of a fetch for `(entity_type, entity_id, source)`.

  `status` is an atom (`:ok | :empty | :error | :ineligible | :pending`). Options:

    * `:base_date` — the entity's age key (movie `release_date` / person
      latest-credit `Date`/`DateTime`) — drives the age-tiered TTL.
    * `:error_reason` — stored on `:error`.
    * `:metadata` — merged into the row (e.g. `ttl_override_days`).

  Idempotent upsert on the `(entity_type, entity_id, source)` unique key:
  `:ok` stamps `fetched_at` + resets the attempt counter; `:error` bumps the
  counter and sets a backed-off `stale_after` (escalating to `:ineligible` after
  `Policy.max_error_attempts/0`); `:ineligible` sets `stale_after = nil` (never due).
  """
  def touch(entity_type, entity_id, source, status, opts \\ []) do
    et = to_string(entity_type)
    src = to_string(source)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    base_date = Keyword.get(opts, :base_date)

    existing = Repo.get_by(DataRefresh, entity_type: et, entity_id: entity_id, source: src)
    prev_attempts = (existing && existing.attempt_count) || 0
    prev_fetched = existing && existing.fetched_at
    meta = Keyword.get(opts, :metadata, (existing && existing.metadata) || %{})

    {final_status, attempt_count, fetched_at, stale_after} =
      resolve(status, et, src, base_date, now, prev_attempts, prev_fetched, meta)

    %DataRefresh{}
    |> DataRefresh.changeset(%{
      entity_type: et,
      entity_id: entity_id,
      source: src,
      status: Atom.to_string(final_status),
      fetched_at: fetched_at,
      stale_after: stale_after,
      attempt_count: attempt_count,
      last_attempt_at: now,
      error_reason: Keyword.get(opts, :error_reason),
      metadata: meta
    })
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:entity_type, :entity_id, :source],
      returning: true
    )
  end

  @doc """
  True when `(entity_type, entity_id, source)` is due for a refresh: no ledger
  row, a never-due-but-not-ineligible row, or a past-due `stale_after`.
  """
  def stale?(entity_type, entity_id, source) do
    now = DateTime.utc_now()

    case Repo.get_by(DataRefresh,
           entity_type: to_string(entity_type),
           entity_id: entity_id,
           source: to_string(source)
         ) do
      nil -> true
      %{status: "ineligible"} -> false
      %{stale_after: nil} -> true
      %{stale_after: sa} -> DateTime.compare(sa, now) == :lt
    end
  end

  @doc """
  Stale entity ids for `source`, oldest-due first (#1010 §6 selection:
  `stale_after < now() AND status <> 'ineligible'`). Floor sweepers consume this
  in #1096 Phase C; `:canonical_first` ordering is refined there.
  """
  def due(source, limit, _opts \\ []) do
    now = DateTime.utc_now()
    src = to_string(source)

    from(r in DataRefresh,
      where:
        r.source == ^src and r.status != "ineligible" and not is_nil(r.stale_after) and
          r.stale_after < ^now,
      order_by: [asc: r.stale_after],
      limit: ^limit,
      select: r.entity_id
    )
    |> Repo.all()
  end

  # --- status resolution -----------------------------------------------------

  defp resolve(:ok, et, src, base_date, now, _prev, _prev_fetched, meta) do
    {:ok, 0, now, Policy.stale_after(et, src, base_date, now, status: :ok, metadata: meta)}
  end

  defp resolve(:ineligible, _et, _src, _base_date, _now, prev, prev_fetched, _meta) do
    {:ineligible, prev, prev_fetched, nil}
  end

  defp resolve(:error, _et, _src, _base_date, now, prev, prev_fetched, _meta) do
    attempt = prev + 1

    if attempt >= Policy.max_error_attempts() do
      {:ineligible, attempt, prev_fetched, nil}
    else
      {:error, attempt, prev_fetched, DateTime.add(now, Policy.backoff(attempt), :second)}
    end
  end

  defp resolve(status, et, src, base_date, now, prev, prev_fetched, meta)
       when status in [:empty, :pending] do
    stale = Policy.stale_after(et, src, base_date, now, status: status, metadata: meta)
    {status, prev, prev_fetched, stale}
  end
end
