defmodule Mix.Tasks.Cinegraph.MaterializedViews.RefreshTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Database.Utils, as: DatabaseUtils

  describe "DatabaseUtils.has_unique_index?/1 (#897 Phase B)" do
    # The migration `20250730130132_create_collaboration_materialized_view.exs`
    # creates `person_collaboration_trends` with a UNIQUE index on (person_id, year).
    # Schema migrations run before this test, so the view exists at test time.
    test "returns true for matview with a unique index" do
      assert DatabaseUtils.has_unique_index?("person_collaboration_trends") == true
    end

    test "returns false for an unknown table or view" do
      refute DatabaseUtils.has_unique_index?(
               "definitely_does_not_exist_#{System.unique_integer([:positive])}"
             )
    end

    test "returns false for a regular table without any unique index" do
      table = "tmp_no_unique_idx_#{System.unique_integer([:positive])}"

      Repo.query!(~s|CREATE TABLE "#{table}" (id serial, val int)|)

      try do
        # No PK, no unique index → false
        assert DatabaseUtils.has_unique_index?(table) == false

        Repo.query!(~s|CREATE INDEX ON "#{table}" (val)|)
        # Non-unique index added → still false
        assert DatabaseUtils.has_unique_index?(table) == false

        Repo.query!(~s|CREATE UNIQUE INDEX ON "#{table}" (id)|)
        # Unique index added → true
        assert DatabaseUtils.has_unique_index?(table) == true
      after
        Repo.query!(~s|DROP TABLE IF EXISTS "#{table}"|)
      end
    end

    test "returns false for partial and expression unique indexes" do
      table = "tmp_unqualified_unique_idx_#{System.unique_integer([:positive])}"
      partial_index = "#{table}_partial_idx"
      expression_index = "#{table}_expression_idx"

      Repo.query!(~s|CREATE TABLE "#{table}" (id int, val int)|)

      try do
        Repo.query!(
          ~s|CREATE UNIQUE INDEX "#{partial_index}" ON "#{table}" (id) WHERE val IS NOT NULL|
        )

        assert DatabaseUtils.has_unique_index?(table) == false

        Repo.query!(~s|DROP INDEX IF EXISTS "#{partial_index}"|)
        Repo.query!(~s|CREATE UNIQUE INDEX "#{expression_index}" ON "#{table}" ((val + 1))|)
        assert DatabaseUtils.has_unique_index?(table) == false
      after
        Repo.query!(~s|DROP TABLE IF EXISTS "#{table}"|)
      end
    end
  end
end
