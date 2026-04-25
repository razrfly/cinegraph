defmodule Cinegraph.Workers.PersonTmdbRefreshWorkerTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Workers.PersonTmdbRefreshWorker

  describe "perform/1" do
    test "returns {:cancel, :person_not_found} when the person is gone" do
      job = %Oban.Job{args: %{"person_id" => 999_999_999}}
      assert {:cancel, :person_not_found} = PersonTmdbRefreshWorker.perform(job)
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
