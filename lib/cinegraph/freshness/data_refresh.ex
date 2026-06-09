defmodule Cinegraph.Freshness.DataRefresh do
  @moduledoc """
  The polymorphic freshness ledger row (#1096 Phase B / #1010 substrate).

  One row per `(entity_type, entity_id, source)`. Generalizes
  `Cinegraph.Movies.MovieAvailabilityRefresh` — the one source that already had a
  freshness ledger — with two changes:

    * **Status vocabulary** is the #1010 §6 set (`pending | ok | empty | error |
      ineligible`), not the prototype's `success/no_results/error`. The
      availability statuses map on backfill (success→ok, no_results→empty).
    * **`fetched_at` / `stale_after` are optional** — NULL `fetched_at` means
      never fetched, NULL `stale_after` means never due (ineligible/frozen). The
      temporal check (`stale_after > fetched_at`) only fires when both are set.

  Stores freshness *metadata only*; values stay in `external_metrics`/blobs.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending ok empty error ineligible)

  schema "data_refreshes" do
    field :entity_type, :string
    field :entity_id, :integer
    field :source, :string
    field :fetched_at, :utc_datetime
    field :stale_after, :utc_datetime
    field :status, :string, default: "pending"
    field :error_reason, :string
    field :attempt_count, :integer, default: 0
    field :last_attempt_at, :utc_datetime
    field :last_checked_at, :utc_datetime
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @required_fields [:entity_type, :entity_id, :source, :status]
  @optional_fields [
    :fetched_at,
    :stale_after,
    :error_reason,
    :attempt_count,
    :last_attempt_at,
    :last_checked_at,
    :metadata
  ]

  def changeset(refresh, attrs) do
    refresh
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_temporal_consistency()
    |> unique_constraint([:entity_type, :entity_id, :source],
      name: :data_refreshes_unique_idx
    )
  end

  # Mirrors the prototype: no-ops unless BOTH timestamps are present (so
  # never-fetched / never-due rows are allowed here, unlike availability).
  defp validate_temporal_consistency(changeset) do
    fetched_at = get_field(changeset, :fetched_at)
    stale_after = get_field(changeset, :stale_after)

    if fetched_at && stale_after && DateTime.compare(stale_after, fetched_at) != :gt do
      add_error(changeset, :stale_after, "must be after fetched_at")
    else
      changeset
    end
  end

  def statuses, do: @statuses
end
