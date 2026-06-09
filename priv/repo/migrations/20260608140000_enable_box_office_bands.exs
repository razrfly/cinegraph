defmodule Cinegraph.Repo.Migrations.EnableBoxOfficeBands do
  @moduledoc """
  #1087: switch the ML data-point surface from raw box-office codes to box-office BAND one-hots.

  A CLEAN per-list holdout test (raw-vs-band, backtest strategy held fixed, same sacred holdout)
  showed the box-office band families raise served recall@K on 6 lists (ss_critics, tspdt, criterion,
  letterboxd, ebert, cult), neutral on 1001/ss_directors. This syncs `is_available` on EXISTING rows
  to match `CatalogSeed` (the source of truth; `seed!/0` creates the band rows). Flag-only — no scores
  recomputed; the box_office LENS reads budget/revenue via `FeatureResolver` named inputs (not
  `is_available`), so lens scores are unchanged. Reversible.
  """
  use Ecto.Migration

  import Ecto.Query

  @bo_raw ~w(tmdb_revenue_worldwide omdb_revenue_domestic tmdb_budget box_office_roi)
  @bo_prefixes ~w(rev_ww rev_dom budget roi)

  def up do
    flip(bo_bands(), true)
    flip(@bo_raw, false)
  end

  def down do
    flip(bo_bands(), false)
    flip(@bo_raw, true)
  end

  defp bo_bands,
    do: Enum.flat_map(@bo_prefixes, &Cinegraph.Scoring.DerivedFeatures.band_codes_for/1)

  defp flip(codes, available?) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    repo().update_all(
      from(d in "metric_definitions", where: d.code in ^codes),
      set: [is_available: available?, updated_at: now]
    )
  end
end
