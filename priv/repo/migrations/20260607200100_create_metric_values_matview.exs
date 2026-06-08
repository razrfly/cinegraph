defmodule Cinegraph.Repo.Migrations.CreateMetricValuesMatview do
  use Ecto.Migration

  # #1082 / #1084 P1: the structural unit-cost fix. Feature loading re-derived
  # normalization through the 7-branch UNION on every read (~11.5ms/movie on prod;
  # full-pool rankings 4–50 min/list). This materializes the (now dedup-guaranteed,
  # see 20260607200000) view so the hot shape
  #   WHERE movie_id = ANY($1) AND metric_code = ANY($2)
  # becomes an index scan.
  #
  # Created WITH NO DATA deliberately: the first populate is an explicit, observable
  # ops step on prod (REFRESH MATERIALIZED VIEW metric_values_matview — minutes over
  # 3.8M external_metrics rows), NOT a deploy-blocking migration. Until that first
  # refresh the matview is empty — which read paths tolerate because the relation is
  # selected by the :metric_values_relation config knob (test/default = the live view;
  # dev/prod = this matview, flipped only alongside the first refresh).
  #
  # The unique index makes it eligible for REFRESH ... CONCURRENTLY, so the daily
  # MaterializedViewRefreshSweeper (08:00 UTC, refresh_all(concurrently_only: true))
  # keeps it fresh automatically. Freshness bound = 24h, same staleness class as the
  # DisplayCache rankings it feeds (warmer-owned, #1084 A.1).
  def up do
    execute """
    CREATE MATERIALIZED VIEW metric_values_matview AS
    SELECT * FROM metric_values_view
    WITH NO DATA
    """

    # Leads with movie_id → serves the hot `movie_id = ANY($1)` shape directly;
    # uniqueness is guaranteed by the view's outer GROUP BY (movie_id, metric_code).
    execute """
    CREATE UNIQUE INDEX metric_values_matview_movie_code_idx
    ON metric_values_matview (movie_id, metric_code)
    """
  end

  def down do
    execute "DROP MATERIALIZED VIEW IF EXISTS metric_values_matview"
  end
end
