defmodule Cinegraph.Workers.TMDbDetailsWorkerTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Workers.TMDbDetailsWorker

  # #1007 — Repo.Worker routing is the primary isolation mechanism preventing
  # TMDbDetailsWorker from starving web requests for Repo.Replica connections.
  # These tests lock down the contract so a future refactor can't silently
  # revert to hitting the web replica pool during the pre-write exists? check.
  describe "queue contract" do
    test "TMDbDetailsWorker targets :tmdb queue" do
      job = TMDbDetailsWorker.new(%{"tmdb_id" => 1})
      assert job.changes.queue == "tmdb"
    end

    test "tmdb_id perform/1 routes replica calls through Repo.Worker" do
      assert_job_repo_set(%{"tmdb_id" => 99_999_999})
    end

    test "imdb_id perform/1 routes replica calls through Repo.Worker" do
      assert_job_repo_set(%{"imdb_id" => "tt9999999"})
    end
  end

  # Spawn perform/1 in a separate process, rescue any crash (e.g. missing API
  # key in test env), then check the process dict. Process.put fires as the
  # very first statement of each perform clause, before any API or DB call,
  # so the dict is set even if the job fails partway through.
  defp assert_job_repo_set(args) do
    parent = self()

    {:ok, _pid} =
      Task.start(fn ->
        job = %Oban.Job{
          args: args,
          attempt: 1,
          max_attempts: 1,
          queue: "tmdb",
          worker: "Cinegraph.Workers.TMDbDetailsWorker",
          id: 0,
          inserted_at: DateTime.utc_now(),
          scheduled_at: DateTime.utc_now()
        }

        try do
          TMDbDetailsWorker.perform(job)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end

        send(parent, {:job_repo, Process.get(:cinegraph_job_repo)})
      end)

    assert_receive {:job_repo, Cinegraph.Repo.Worker}, 5_000
  end
end
