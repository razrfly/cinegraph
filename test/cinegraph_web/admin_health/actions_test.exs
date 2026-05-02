defmodule CinegraphWeb.AdminHealth.ActionsTest do
  use Cinegraph.DataCase, async: false

  alias CinegraphWeb.AdminHealth.Actions

  setup do
    # Sandbox doesn't roll back across tests reliably with shared mode + Oban
    # — clear oban_jobs so per-test counts are deterministic.
    Repo.delete_all(Oban.Job)
    :ok
  end

  describe "queue_omdb_refresh/1" do
    test "empty list returns {:ok, 0} without inserting" do
      assert {:ok, 0} = Actions.queue_omdb_refresh([])
      assert Repo.aggregate(Oban.Job, :count, :id) == 0
    end

    test "inserts an OMDbEnrichmentWorker job per id with force: true" do
      assert {:ok, 3} = Actions.queue_omdb_refresh([101, 102, 103])

      jobs = Repo.all(Oban.Job)
      assert length(jobs) == 3
      assert Enum.all?(jobs, &(&1.worker == "Cinegraph.Workers.OMDbEnrichmentWorker"))
      assert Enum.all?(jobs, &(&1.args["force"] == true))

      ids = Enum.map(jobs, & &1.args["movie_id"]) |> Enum.sort()
      assert ids == [101, 102, 103]
    end

    test "uniqueness deduplicates a duplicate enqueue (same hour)" do
      assert {:ok, 1} = Actions.queue_omdb_refresh([200])
      assert {:ok, 1} = Actions.queue_omdb_refresh([200])
      assert Repo.aggregate(Oban.Job, :count, :id) == 1
    end
  end

  describe "queue_person_tmdb_refresh/1" do
    test "empty list returns {:ok, 0}" do
      assert {:ok, 0} = Actions.queue_person_tmdb_refresh([])
    end

    test "inserts a PersonTmdbRefreshWorker job per id" do
      assert {:ok, 2} = Actions.queue_person_tmdb_refresh([1, 2])

      jobs = Repo.all(Oban.Job)
      assert length(jobs) == 2
      assert Enum.all?(jobs, &(&1.worker == "Cinegraph.Workers.PersonTmdbRefreshWorker"))

      ids = Enum.map(jobs, & &1.args["person_id"]) |> Enum.sort()
      assert ids == [1, 2]
      assert Enum.all?(jobs, &(&1.queue == "tmdb"))
    end
  end

  describe "queue_availability_refresh/1" do
    test "empty list returns {:ok, 0}" do
      assert {:ok, 0} = Actions.queue_availability_refresh([])
    end

    test "inserts a forced MovieAvailabilityRefreshWorker job per id" do
      assert {:ok, 2} = Actions.queue_availability_refresh([1, 2])

      jobs = Repo.all(Oban.Job)
      assert length(jobs) == 2
      assert Enum.all?(jobs, &(&1.worker == "Cinegraph.Workers.MovieAvailabilityRefreshWorker"))
      assert Enum.all?(jobs, &(not Map.has_key?(&1.args, "regions")))
      assert Enum.all?(jobs, &(&1.args["force"] == true))
      assert Enum.all?(jobs, &(&1.args["source"] == "manual"))
      assert Enum.map(jobs, & &1.args["movie_id"]) |> Enum.sort() == [1, 2]
    end
  end

  test "Actions source file imports no Cinegraph.Repo (architectural guard)" do
    src = File.read!("lib/cinegraph_web/admin_health/actions.ex")
    refute src =~ "alias Cinegraph.Repo"
    refute src =~ "Cinegraph.Repo."
  end
end
