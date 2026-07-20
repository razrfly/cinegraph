defmodule Cinegraph.ListEvents.ListMembershipEventsTest do
  use Cinegraph.DataCase, async: true

  alias Cinegraph.ListEvents.{ListMembershipEvent, ListMembershipEvents}
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Repo

  defp insert_movie(attrs) do
    %Movie{}
    |> Movie.changeset(Map.put_new(attrs, :tmdb_id, System.unique_integer([:positive])))
    |> Repo.insert!()
  end

  defp count(source_key) do
    Repo.aggregate(
      from(e in ListMembershipEvent, where: e.source_key == ^source_key),
      :count
    )
  end

  describe "upsert_events/1 idempotency" do
    test "re-running does not grow the row count (matched + pending)" do
      movie = insert_movie(%{title: "Casablanca", release_date: ~D[1942-11-26]})

      rows = [
        %{
          source_key: "nfr_test",
          movie_id: movie.id,
          event_type: "added",
          event_edition: "nfr_1989",
          raw_title: "Casablanca",
          raw_year: 1942
        },
        %{
          source_key: "nfr_test",
          event_type: "added",
          event_edition: "nfr_1989",
          raw_title: "An Unmatched Film",
          raw_year: 1950
        }
      ]

      assert %{matched: 1, pending: 1} = ListMembershipEvents.upsert_events(rows)
      assert count("nfr_test") == 2

      # Idempotent: three more runs do not add rows.
      ListMembershipEvents.upsert_events(rows)
      ListMembershipEvents.upsert_events(rows)
      ListMembershipEvents.upsert_events(rows)
      assert count("nfr_test") == 2
    end

    test "dedups duplicate rows within a single batch" do
      rows = [
        %{
          source_key: "dup_test",
          event_type: "added",
          event_edition: "e1",
          raw_title: "Twice",
          raw_year: 2000
        },
        %{
          source_key: "dup_test",
          event_type: "added",
          event_edition: "e1",
          raw_title: "Twice",
          raw_year: 2000
        }
      ]

      assert %{pending: 1} = ListMembershipEvents.upsert_events(rows)
      assert count("dup_test") == 1
    end

    test "matched and pending rows for the same identity coexist" do
      movie = insert_movie(%{title: "Vertigo", release_date: ~D[1958-05-09]})

      ListMembershipEvents.upsert_events([
        %{
          source_key: "coexist",
          movie_id: movie.id,
          event_type: "added",
          event_edition: "e1",
          raw_title: "Vertigo",
          raw_year: 1958
        },
        %{
          source_key: "coexist",
          event_type: "added",
          event_edition: "e1",
          raw_title: "Vertigo",
          raw_year: 1958
        }
      ])

      assert count("coexist") == 2
    end
  end

  describe "coverage_for/1" do
    test "tallies found/matched/pending and adds/removes" do
      movie = insert_movie(%{title: "M", release_date: ~D[1931-05-11]})

      ListMembershipEvents.upsert_events([
        %{
          source_key: "cov",
          movie_id: movie.id,
          event_type: "added",
          event_edition: "2003",
          raw_title: "M",
          raw_year: 1931
        },
        %{
          source_key: "cov",
          event_type: "added",
          event_edition: "2006",
          raw_title: "Unmatched A",
          raw_year: 1960
        },
        %{
          source_key: "cov",
          event_type: "removed",
          event_edition: "2008",
          raw_title: "Unmatched B",
          raw_year: 1970
        }
      ])

      cov = ListMembershipEvents.coverage_for("cov")

      assert cov.found == 3
      assert cov.matched == 1
      assert cov.pending == 2
      assert cov.adds == 2
      assert cov.removes == 1
      assert cov.adds_matched == 1
      assert cov.removes_matched == 0
      assert cov.editions == ["2003", "2006", "2008"]
    end
  end

  describe "reconcile/1" do
    test "net matched adds minus removes vs current membership" do
      m1 = insert_movie(%{title: "A1", release_date: ~D[1990-01-01]})
      m2 = insert_movie(%{title: "A2", release_date: ~D[1991-01-01]})

      ListMembershipEvents.upsert_events([
        %{
          source_key: "rec",
          movie_id: m1.id,
          event_type: "added",
          event_edition: "e1",
          raw_title: "A1",
          raw_year: 1990
        },
        %{
          source_key: "rec",
          movie_id: m2.id,
          event_type: "added",
          event_edition: "e1",
          raw_title: "A2",
          raw_year: 1991
        },
        %{
          source_key: "rec",
          movie_id: m2.id,
          event_type: "removed",
          event_edition: "e2",
          raw_title: "A2",
          raw_year: 1991
        }
      ])

      recon = ListMembershipEvents.reconcile("rec")
      # 2 adds - 1 remove = 1 net add; no movie carries canonical_sources["rec"] → 0 current
      assert recon.net_adds == 1
      assert recon.current_members == 0
      assert recon.discrepancy == 1
      refute recon.reconciled?
    end
  end

  describe "promote_pending/2" do
    test "moves a pending row to matched" do
      movie = insert_movie(%{title: "Nashville", release_date: ~D[1975-06-11]})

      ListMembershipEvents.upsert_events([
        %{
          source_key: "promo",
          event_type: "added",
          event_edition: "e1",
          raw_title: "Nashville",
          raw_year: 1975
        }
      ])

      [event] = Repo.all(from e in ListMembershipEvent, where: e.source_key == "promo")
      assert event.match_state == "pending"

      assert {:ok, updated} = ListMembershipEvents.promote_pending(event.id, movie.id)
      assert updated.match_state == "matched"
      assert updated.movie_id == movie.id
    end
  end
end
