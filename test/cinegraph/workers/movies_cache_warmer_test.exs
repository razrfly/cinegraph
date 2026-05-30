defmodule Cinegraph.Workers.MoviesCacheWarmerTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Movies.Cache
  alias Cinegraph.Workers.MoviesCacheWarmer

  # #1007 — MoviesCacheWarmer.perform/1 now warms filter options (line 48) in
  # addition to popular search queries, so PersonLive.Movies mounts after a
  # deploy hit a warm cache rather than hammering Repo.Replica cold.
  # These tests lock down: (a) the Repo.Worker routing contract, and (b) that
  # filter options are actually written to the cache after a perform run.

  setup do
    {:ok, _} = Cachex.clear(:movies_cache)
    :ok
  end

  defp run_warmer do
    job = %Oban.Job{
      args: %{},
      attempt: 1,
      max_attempts: 3,
      queue: "maintenance",
      worker: "Cinegraph.Workers.MoviesCacheWarmer",
      id: 0,
      inserted_at: DateTime.utc_now(),
      scheduled_at: DateTime.utc_now()
    }

    MoviesCacheWarmer.perform(job)
  end

  describe "queue contract" do
    test "perform/1 routes replica calls through Repo.Worker" do
      Process.delete(:cinegraph_job_repo)
      run_warmer()
      assert Process.get(:cinegraph_job_repo) == Cinegraph.Repo.Worker
    end
  end

  describe "filter options warming" do
    test "perform/1 populates the filter options cache" do
      # Cache is empty after setup
      assert {:ok, nil} = Cachex.get(:movies_cache, "filter_options")

      run_warmer()

      # After the warmer runs, filter options must be present
      assert {:ok, filter_options} = Cachex.get(:movies_cache, "filter_options")

      assert is_map(filter_options),
             "Expected filter_options to be a map, got: #{inspect(filter_options)}"

      assert Map.has_key?(filter_options, :genres), "Expected :genres key in filter_options"

      assert Map.has_key?(filter_options, :sort_options),
             "Expected :sort_options key in filter_options"
    end

    test "perform/1 returns ok with warmed count" do
      assert {:ok, result} = run_warmer()
      assert is_integer(result.warmed_count)
      assert is_integer(result.elapsed_ms)
    end
  end
end
