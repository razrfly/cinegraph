defmodule Cinegraph.Repo.Migrations.CreateListMembershipEvents do
  use Ecto.Migration

  @moduledoc """
  #1115 (R3 prep, child of #1114) — addition-event ground truth.

  One row per (list, movie, event): records when a film was ADDED or REMOVED
  from a canonical list edition. The DB previously held only current-union
  membership (`movies.canonical_sources` JSONB) with no edition diffs or
  induction years, so "predict the next edition's additions" had no labels.

  Append-only by convention — events are facts, never updated in place.

  `movie_id` is NULLABLE: unmatched scrapes are kept in a `pending` match_state
  with their raw identity (raw_title/raw_year/raw_imdb_id) so nothing is silently
  dropped — they are re-matchable later. The two partial unique indexes give
  matched and pending rows separate idempotency keys (Postgres treats NULLs as
  distinct, so a single non-partial unique index could not dedup both).
  """

  def change do
    create table(:list_membership_events) do
      add :source_key, :string, null: false, size: 100
      # NULLABLE — pending rows (unmatched scrape) carry no movie_id yet.
      add :movie_id, references(:movies, on_delete: :nilify_all)
      add :event_type, :string, null: false, size: 20
      add :event_edition, :string, null: false, size: 50
      # when known (e.g. NFR induction announcement); NULL otherwise.
      add :event_date, :date
      # "matched" once movie_id is set, "pending" while unmatched.
      add :match_state, :string, null: false, default: "pending", size: 20

      # Raw scrape identity — kept so pending rows are never lost and can be
      # re-matched later by a backfill pass.
      add :raw_title, :string
      add :raw_year, :integer
      add :raw_imdb_id, :string, size: 20

      add :source_url, :text
      add :provenance, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    # (a) Matched-row dedup — the issue's canonical key + the insert_all conflict
    #     target for matched rows. Partial because NULL movie_ids must be excluded.
    create unique_index(
             :list_membership_events,
             [:source_key, :movie_id, :event_type, :event_edition],
             where: "movie_id IS NOT NULL",
             name: :lme_matched_unique_idx
           )

    # (b) Pending-row dedup — idempotency key on raw identity so re-running a
    #     scraper does not pile up duplicate pending rows. The raw_* columns are
    #     nullable (NFR rows carry no imdb_id), and Postgres treats NULLs as
    #     distinct — so the index COALESCEs them to sentinels, making two pending
    #     rows with the same identity collide even when fields are NULL. The
    #     `upsert_events` conflict target uses the identical expression.
    create unique_index(
             :list_membership_events,
             [
               :source_key,
               :event_type,
               :event_edition,
               "coalesce(raw_imdb_id, '')",
               "coalesce(raw_title, '')",
               "coalesce(raw_year, 0)"
             ],
             where: "movie_id IS NULL",
             name: :lme_pending_unique_idx
           )

    # Coverage / reconciliation rollups — counts per (source_key, event_type, match_state).
    create index(:list_membership_events, [:source_key, :event_type, :match_state],
             name: :lme_source_type_state_idx
           )

    # Per-movie event timeline (induction-year lookups, "what lists added this film").
    create index(:list_membership_events, [:movie_id],
             where: "movie_id IS NOT NULL",
             name: :lme_movie_idx
           )

    # Pending re-match sweep over raw_imdb_id.
    create index(:list_membership_events, [:raw_imdb_id],
             where: "movie_id IS NULL",
             name: :lme_raw_imdb_idx
           )
  end
end
