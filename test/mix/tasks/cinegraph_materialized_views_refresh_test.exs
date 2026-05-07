defmodule Mix.Tasks.Cinegraph.MaterializedViews.RefreshTest do
  use Cinegraph.DataCase, async: false

  alias Mix.Tasks.Cinegraph.MaterializedViews.Refresh

  describe "has_unique_index?/1 (#897 Phase B)" do
    # The migration `20250730130132_create_collaboration_materialized_view.exs`
    # creates `person_collaboration_trends` with a UNIQUE index on (person_id, year).
    # Schema migrations run before this test, so the view exists at test time.
    test "returns true for matview with a unique index" do
      assert Refresh.has_unique_index?("person_collaboration_trends") == true
    end

    test "returns false for an unknown table or view" do
      refute Refresh.has_unique_index?("definitely_does_not_exist_#{System.unique_integer([:positive])}")
    end

    test "returns false for a regular table without any unique index" do
      table = "tmp_no_unique_idx_#{System.unique_integer([:positive])}"

      Repo.query!(~s|CREATE TABLE "#{table}" (id serial, val int)|)

      try do
        # No PK, no unique index → false
        assert Refresh.has_unique_index?(table) == false

        Repo.query!(~s|CREATE INDEX ON "#{table}" (val)|)
        # Non-unique index added → still false
        assert Refresh.has_unique_index?(table) == false

        Repo.query!(~s|CREATE UNIQUE INDEX ON "#{table}" (id)|)
        # Unique index added → true
        assert Refresh.has_unique_index?(table) == true
      after
        Repo.query!(~s|DROP TABLE IF EXISTS "#{table}"|)
      end
    end
  end
end
