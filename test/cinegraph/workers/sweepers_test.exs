defmodule Cinegraph.Workers.SweepersTest do
  @moduledoc """
  Smoke tests for the Phase 3 cron-driven sweepers (#735). The maintenance
  modules they wrap are covered in detail by their own tests; here we just
  prove the sweepers' `perform/1` runs to completion against an empty DB
  and reports zero-found / zero-enqueued cleanly.
  """
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Workers.{
    BiographyRefreshSweeper,
    FestivalPersonResolverSweeper,
    FestivalSyncSweeper,
    ImdbIdRepairSweeper,
    OmdbBackfillSweeper,
    ProfileDataRefreshSweeper,
    ZeroCreditsCleanupDeleteSweeper,
    ZeroCreditsCleanupSweeper
  }

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

  describe "OmdbBackfillSweeper.perform/1 (#745 Phase 1.1)" do
    test "returns :ok with zero found on empty DB" do
      assert {:ok, %{found: 0, enqueued: 0, failed: 0, dry_run: false}} =
               OmdbBackfillSweeper.perform(%Oban.Job{})
    end
  end

  describe "ImdbIdRepairSweeper.perform/1 (#745 Phase 1.2)" do
    test "returns :ok with zero found on empty DB" do
      assert {:ok, %{found: 0, enqueued: 0, failed: 0, dry_run: false}} =
               ImdbIdRepairSweeper.perform(%Oban.Job{})
    end
  end

  describe "ProfileDataRefreshSweeper.perform/1 (#745 Phase 1.3 + 1.6)" do
    test "returns :ok with zero found on empty DB" do
      assert {:ok, %{found: 0, enqueued: 0, failed: 0, dry_run: false}} =
               ProfileDataRefreshSweeper.perform(%Oban.Job{})
    end
  end

  describe "ZeroCreditsCleanupSweeper.perform/1 (#745 Phase 1.5 phase 1)" do
    test "returns :ok with zero found on empty DB" do
      assert {:ok, %{found: 0, enqueued: 0, failed: 0, dry_run: false, phase: :enqueue}} =
               ZeroCreditsCleanupSweeper.perform(%Oban.Job{})
    end
  end

  describe "ZeroCreditsCleanupDeleteSweeper.perform/1 (#745 Phase 1.5 phase 2)" do
    test "returns :ok with zero found on empty DB" do
      assert {:ok, %{found: 0, deleted: 0, failed: 0, dry_run: false, phase: :delete}} =
               ZeroCreditsCleanupDeleteSweeper.perform(%Oban.Job{})
    end
  end

  describe "FestivalSyncSweeper.perform/1 (#745 Phase 2)" do
    test "returns :ok with empty stats on empty DB" do
      assert {:ok,
              %{
                events: 0,
                discoveries_enqueued: 0,
                discoveries_already_queued: 0,
                imports_enqueued: 0,
                imports_already_queued: 0,
                failed: 0,
                dry_run: false
              }} = FestivalSyncSweeper.perform(%Oban.Job{})
    end
  end
end
