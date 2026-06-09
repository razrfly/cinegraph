defmodule Cinegraph.Repo.Migrations.CreateDataRefreshes do
  use Ecto.Migration

  @moduledoc """
  #1096 Phase B / #1090 Phase 1 / first child of #1010 — the freshness substrate.

  One polymorphic freshness ledger generalizing `movie_availability_refreshes`
  (the one source that already had this shape). Stores freshness *metadata only*
  — actual values stay in `external_metrics`, `movies.omdb_data`, etc.

  Unlike the prototype, `fetched_at` and `stale_after` are NULLABLE here: a row
  can exist for a source that has never been fetched (NULL fetched_at) or that is
  ineligible/frozen (NULL stale_after = never due). This is what gives the
  freshness-blind sources (tmdb_details, person) a freshness signal for the first
  time. Polymorphic (entity_type, entity_id) → no single FK.
  """

  def change do
    create table(:data_refreshes) do
      add :entity_type, :string, null: false, size: 50
      add :entity_id, :bigint, null: false
      add :source, :string, null: false, size: 50
      # NULL fetched_at = never successfully fetched; NULL stale_after = never due.
      add :fetched_at, :utc_datetime
      add :stale_after, :utc_datetime
      add :status, :string, null: false, default: "pending", size: 20
      add :error_reason, :text
      add :attempt_count, :integer, null: false, default: 0
      # includes FAILED attempts (drives error backoff)
      add :last_attempt_at, :utc_datetime
      # read-through canary (#1010 Phase 5) — nothing writes this yet
      add :last_checked_at, :utc_datetime
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:data_refreshes, [:entity_type, :entity_id, :source],
             name: :data_refreshes_unique_idx
           )

    # due/2 — "what's stale for source X?"
    create index(:data_refreshes, [:source, :stale_after])
    # per-entity freshness panel
    create index(:data_refreshes, [:entity_type, :entity_id])
    # report rollup — counts per (source, status)
    create index(:data_refreshes, [:source, :status])
  end
end
