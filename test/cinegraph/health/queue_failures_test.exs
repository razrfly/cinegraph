defmodule Cinegraph.Health.QueueFailuresTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Health.QueueFailures

  doctest QueueFailures, only: [classify_error: 1]

  describe "audit/1" do
    test "raises when neither :queue nor :worker is given" do
      assert_raise ArgumentError, fn -> QueueFailures.audit(days: 7) end
    end

    test "raises when :days or :top_n are not positive integers" do
      assert_raise ArgumentError, ":days must be a positive integer, got: 0", fn ->
        QueueFailures.audit(queue: "test_q", days: 0)
      end

      assert_raise ArgumentError, ":top_n must be a positive integer, got: -1", fn ->
        QueueFailures.audit(queue: "test_q", top_n: -1)
      end
    end

    test "filter by queue returns the per-pattern + per-worker rollup" do
      err1 = oban_error(~s|HTTP 429 Too Many Requests|)
      err2 = oban_error(~s|HTTP 502 Bad Gateway|)
      err3 = oban_error(~s|:timeout|)

      insert_discard(queue: "test_q", worker: "WorkerA", error: err1, hours_ago: 2)
      insert_discard(queue: "test_q", worker: "WorkerA", error: err1, hours_ago: 3)
      insert_discard(queue: "test_q", worker: "WorkerB", error: err2, hours_ago: 4)
      insert_discard(queue: "test_q", worker: "WorkerB", error: err3, hours_ago: 5)
      # Different queue — should be filtered out
      insert_discard(queue: "other_q", worker: "WorkerA", error: err1, hours_ago: 1)

      result = QueueFailures.audit(queue: "test_q", days: 7)

      assert result.summary.total_discarded == 4
      assert result.summary.by_worker == %{"WorkerA" => 2, "WorkerB" => 2}
      assert result.summary.by_error_pattern == %{rate_limit: 2, http_5xx: 1, network: 1}
      assert result.filter == %{queue: "test_q", worker: nil}

      patterns = Enum.map(result.top_errors, & &1.pattern)
      assert :rate_limit in patterns
      assert :http_5xx in patterns
      assert :network in patterns
    end

    test "filter by worker narrows to that worker only" do
      err = oban_error(~s|HTTP 429|)

      insert_discard(queue: "shared_q", worker: "WorkerX", error: err, hours_ago: 2)
      insert_discard(queue: "shared_q", worker: "WorkerY", error: err, hours_ago: 3)

      result = QueueFailures.audit(worker: "WorkerX", days: 7)

      assert result.summary.total_discarded == 1
      assert result.summary.by_worker == %{"WorkerX" => 1}
    end

    test "ignores discards outside the --days window" do
      err = oban_error(~s|HTTP 502|)

      insert_discard(queue: "t_q", worker: "W", error: err, hours_ago: 24 * 30)

      result = QueueFailures.audit(queue: "t_q", days: 7)
      assert result.summary.total_discarded == 0
    end

    test "top_errors entries include sample_workers and sample_error" do
      err = oban_error(~s|HTTP 429 Too Many Requests|)

      insert_discard(queue: "tt_q", worker: "WorkerOne", error: err, hours_ago: 1)
      insert_discard(queue: "tt_q", worker: "WorkerTwo", error: err, hours_ago: 2)

      result = QueueFailures.audit(queue: "tt_q", days: 7, top_n: 3)
      [top | _] = result.top_errors

      assert top.pattern == :rate_limit
      assert top.count == 2
      assert top.pct == 100.0
      assert top.sample_error =~ "HTTP 429"
      assert MapSet.new(top.sample_workers) == MapSet.new(["WorkerOne", "WorkerTwo"])
    end

    test "top_errors ordering and samples are deterministic for ties" do
      rate_limit = oban_error(~s|HTTP 429 Too Many Requests|)
      timeout = oban_error(~s|:timeout|)

      insert_discard(queue: "tie_q", worker: "WorkerZ", error: timeout, hours_ago: 1)
      insert_discard(queue: "tie_q", worker: "WorkerA", error: rate_limit, hours_ago: 2)

      result = QueueFailures.audit(queue: "tie_q", days: 7, top_n: 2)

      assert Enum.map(result.top_errors, & &1.pattern) == [:network, :rate_limit]
      assert [%{sample_workers: ["WorkerZ"]}, %{sample_workers: ["WorkerA"]}] = result.top_errors
    end
  end

  defp oban_error(msg),
    do: ~s|** (Oban.PerformError) Cinegraph.Workers.NoopWorker failed with {:error, "#{msg}"}|

  defp insert_discard(opts) do
    queue = Keyword.fetch!(opts, :queue)
    worker = Keyword.fetch!(opts, :worker)
    error_text = Keyword.fetch!(opts, :error)
    hours_ago = Keyword.get(opts, :hours_ago, 1)

    discarded_at = DateTime.utc_now() |> DateTime.add(-hours_ago * 3600, :second)

    %Oban.Job{
      args: %{},
      worker: worker,
      queue: queue,
      state: "discarded",
      discarded_at: discarded_at,
      attempt: 3,
      max_attempts: 3,
      errors: [
        %{"at" => DateTime.to_iso8601(discarded_at), "attempt" => 3, "error" => error_text}
      ],
      inserted_at: DateTime.utc_now() |> DateTime.add(-hours_ago * 3600 - 60, :second),
      scheduled_at: DateTime.utc_now() |> DateTime.add(-hours_ago * 3600 - 60, :second)
    }
    |> Repo.insert!()
  end
end
