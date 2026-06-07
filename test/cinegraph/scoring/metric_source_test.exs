defmodule Cinegraph.Scoring.MetricSourceTest do
  @moduledoc """
  #1084 P1 bootstrap safety: a configured-but-unpopulated matview must NEVER be served —
  between deploy and the first REFRESH it would return zero features (silently wrong
  rankings, cached for hours). `MetricSource.relation/0` falls back to the live view
  until `pg_matviews.ispopulated` flips, then latches.
  """
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Scoring.MetricSource

  setup do
    MetricSource.reset_latch()
    original = Application.get_env(:cinegraph, :metric_values_relation)

    on_exit(fn ->
      Application.put_env(:cinegraph, :metric_values_relation, original)
      MetricSource.reset_latch()
    end)

    :ok
  end

  test "configured view passes through untouched" do
    Application.put_env(:cinegraph, :metric_values_relation, "metric_values_view")
    assert MetricSource.relation() == "metric_values_view"
  end

  test "configured matview falls back to the live view while unpopulated, serves after refresh" do
    Application.put_env(:cinegraph, :metric_values_relation, "metric_values_matview")

    # The test DB's matview ships WITH NO DATA and is never refreshed by migrations.
    assert MetricSource.relation() == "metric_values_view"

    # First populate → the latch flips and the matview is served.
    Repo.query!("REFRESH MATERIALIZED VIEW metric_values_matview", [], timeout: 60_000)
    assert MetricSource.relation() == "metric_values_matview"

    # Latched: no further catalog queries needed (still the matview on repeat reads).
    assert MetricSource.relation() == "metric_values_matview"
  end

  test "an unknown relation raises" do
    Application.put_env(:cinegraph, :metric_values_relation, "movies; DROP TABLE movies")
    assert_raise ArgumentError, fn -> MetricSource.relation() end
  end
end
