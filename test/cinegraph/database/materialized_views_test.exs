defmodule Cinegraph.Database.MaterializedViewsTest do
  @moduledoc """
  #1088 regression: `refresh_all!/1` must isolate per-view failures. Before the fix, one
  matview whose refresh raised (e.g. an `exp()` underflow in its defining query) aborted the
  ENTIRE sweep — every healthy view went stale and the sweeper discarded silently.
  """
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Database.MaterializedViews

  # Both created WITH NO DATA so `refresh!` takes the non-concurrent populate branch
  # (CONCURRENTLY can't run inside the test sandbox transaction). The "bad" one's query
  # underflows on refresh exactly like the prod `movie_discovery_rankings_mv` did.
  defp create_test_matviews! do
    suffix = System.unique_integer([:positive])
    good = "t_mv_good_#{suffix}"
    bad = "t_mv_bad_#{suffix}"

    Repo.query!(~s|CREATE MATERIALIZED VIEW "#{good}" AS SELECT 1 AS id WITH NO DATA|)

    Repo.query!(
      ~s|CREATE MATERIALIZED VIEW "#{bad}" AS SELECT exp(-1000.0::float8) AS x, 1 AS id WITH NO DATA|
    )

    {good, bad}
  end

  test "refresh_all!/1 isolates a failing view — healthy views still refresh, no raise" do
    {good, bad} = create_test_matviews!()

    # Must NOT raise even though `bad` underflows on refresh.
    results = MaterializedViews.refresh_all!()

    assert results[good] == :ok, "a healthy view must refresh despite a sibling failing"
    assert {:error, msg} = results[bad]
    assert msg =~ "underflow", "the failing view is reported with its error, not silently dropped"

    # Both views were processed — iteration didn't abort at the failure.
    assert Map.has_key?(results, good) and Map.has_key?(results, bad)
  end

  test "MaterializedViewRefreshSweeper surfaces partial failure as {:error, …}" do
    {_good, bad} = create_test_matviews!()

    assert {:error, %{failed: failed}} =
             Cinegraph.Workers.MaterializedViewRefreshSweeper.perform(%Oban.Job{args: %{}})

    assert Enum.any?(failed, fn {name, _msg} -> name == bad end)
  end
end
