defmodule Cinegraph.Workers.PersonTmdbRefreshWorkerTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Workers.PersonTmdbRefreshWorker

  describe "perform/1" do
    test "returns {:cancel, :person_not_found} when the person is gone" do
      job = %Oban.Job{args: %{"person_id" => 999_999_999}}
      assert {:cancel, :person_not_found} = PersonTmdbRefreshWorker.perform(job)
    end
  end

  describe "sparse_person?/1 — :empty vs :ok ledger status (#1101 WS1)" do
    alias Cinegraph.Movies.Person

    test "true (→ :empty) only when bio, profile, and known_for are all blank" do
      assert PersonTmdbRefreshWorker.sparse_person?(%Person{
               biography: nil,
               profile_path: nil,
               known_for_department: nil
             })

      assert PersonTmdbRefreshWorker.sparse_person?(%Person{
               biography: "",
               profile_path: "",
               known_for_department: ""
             })
    end

    test "false (→ :ok) when any field is present (e.g. a photo but no bio)" do
      refute PersonTmdbRefreshWorker.sparse_person?(%Person{
               biography: nil,
               profile_path: "/x.jpg",
               known_for_department: nil
             })

      refute PersonTmdbRefreshWorker.sparse_person?(%Person{
               biography: "a bio",
               profile_path: nil,
               known_for_department: nil
             })
    end
  end

  describe "Oban worker config" do
    test "uses :tmdb queue and max_attempts 3" do
      # The Oban worker macro adds these via @meta — the easiest check is to
      # build a Changeset and inspect its changes.
      changeset = PersonTmdbRefreshWorker.new(%{"person_id" => 42})
      assert changeset.changes.queue == "tmdb"
      assert changeset.changes.worker == "Cinegraph.Workers.PersonTmdbRefreshWorker"
      assert changeset.changes.args == %{"person_id" => 42}
      assert changeset.changes.max_attempts == 3
    end
  end
end
