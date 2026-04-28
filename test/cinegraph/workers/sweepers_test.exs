defmodule Cinegraph.Workers.SweepersTest do
  @moduledoc """
  Smoke tests for the Phase 3 cron-driven sweepers (#735). The maintenance
  modules they wrap are covered in detail by their own tests; here we just
  prove the sweepers' `perform/1` runs to completion against an empty DB
  and reports zero-found / zero-enqueued cleanly.
  """
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Workers.{BiographyRefreshSweeper, FestivalPersonResolverSweeper}

  describe "FestivalPersonResolverSweeper.perform/1" do
    test "returns :ok with zero found on empty DB" do
      assert {:ok, %{found: 0, enqueued: 0, failed: 0, dry_run: false}} =
               FestivalPersonResolverSweeper.perform(%Oban.Job{})
    end
  end

  describe "BiographyRefreshSweeper.perform/1" do
    test "returns :ok with zero found on empty DB" do
      assert {:ok, %{found: 0, enqueued: 0, failed: 0, dry_run: false}} =
               BiographyRefreshSweeper.perform(%Oban.Job{})
    end
  end
end
