defmodule Cinegraph.Health.QueuesTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Health.{ObanReader, Queues}

  describe "snapshot/1" do
    test "returns the full contract shape with all configured queues" do
      snapshot = Queues.snapshot(bypass_cache: true)

      assert %{generated_at: %DateTime{}, queues: queues, total_failures_last_hour: total} =
               snapshot

      assert is_list(queues)
      assert length(queues) > 0
      assert is_integer(total)

      configured = ObanReader.configured_queues()
      snapshot_names = Enum.map(queues, & &1.name) |> Enum.sort()
      assert snapshot_names == Enum.sort(configured)

      Enum.each(queues, fn q ->
        assert is_atom(q.name)
        assert is_integer(q.available) and q.available >= 0
        assert is_integer(q.executing) and q.executing >= 0
        assert is_integer(q.scheduled) and q.scheduled >= 0
        assert is_integer(q.retryable) and q.retryable >= 0
        assert is_integer(q.discarded) and q.discarded >= 0
        assert is_integer(q.cancelled) and q.cancelled >= 0
        assert is_integer(q.failures_last_hour) and q.failures_last_hour >= 0
        assert is_integer(q.longest_running_seconds) and q.longest_running_seconds >= 0
      end)
    end

    test "counts available jobs in a queue" do
      insert_oban_job(queue: "tmdb", state: "available")
      insert_oban_job(queue: "tmdb", state: "available")
      insert_oban_job(queue: "tmdb", state: "executing", attempted_at: minutes_ago(2))

      snapshot = Queues.snapshot(bypass_cache: true)
      tmdb = Enum.find(snapshot.queues, &(&1.name == :tmdb))

      assert tmdb.available == 2
      assert tmdb.executing == 1
      assert tmdb.longest_running_seconds >= 60
    end

    test "counts failures in last hour per queue" do
      insert_oban_job(queue: "omdb", state: "discarded", completed_at: minutes_ago(30))
      insert_oban_job(queue: "omdb", state: "cancelled", completed_at: minutes_ago(15))
      # Old failure outside window — should not count
      insert_oban_job(queue: "omdb", state: "discarded", completed_at: minutes_ago(120))

      snapshot = Queues.snapshot(bypass_cache: true)
      omdb = Enum.find(snapshot.queues, &(&1.name == :omdb))

      assert omdb.failures_last_hour == 2
    end

    test "snapshot includes total_failures_last_hour aggregated across queues" do
      insert_oban_job(queue: "tmdb", state: "discarded", completed_at: minutes_ago(10))
      insert_oban_job(queue: "omdb", state: "cancelled", completed_at: minutes_ago(5))

      snapshot = Queues.snapshot(bypass_cache: true)
      assert snapshot.total_failures_last_hour == 2
    end

    test "uses known queue names when runtime Oban processors are disabled" do
      previous_known = Application.get_env(:cinegraph, :known_oban_queues)
      previous_oban = Application.fetch_env!(:cinegraph, Oban)

      try do
        Application.put_env(:cinegraph, :known_oban_queues, [:tmdb, :collaboration])
        Application.put_env(:cinegraph, Oban, Keyword.merge(previous_oban, queues: []))
        insert_oban_job(queue: "collaboration", state: "available")

        snapshot = Queues.snapshot(bypass_cache: true)

        assert Enum.map(snapshot.queues, & &1.name) == [:tmdb, :collaboration]
        assert Enum.find(snapshot.queues, &(&1.name == :collaboration)).available == 1
      after
        restore_env(:known_oban_queues, previous_known)
        Application.put_env(:cinegraph, Oban, previous_oban)
      end
    end
  end

  describe "ObanReader.configured_queues/0" do
    test "returns the queues configured for Oban" do
      queues = ObanReader.configured_queues()
      assert :tmdb in queues
      assert :omdb in queues
      assert :maintenance in queues
    end
  end

  defp insert_oban_job(opts) do
    queue = Keyword.fetch!(opts, :queue)
    state = Keyword.fetch!(opts, :state)
    attempted_at = Keyword.get(opts, :attempted_at)
    completed_at = Keyword.get(opts, :completed_at)

    # Oban stores per-terminal-state timestamps in dedicated columns
    {completed_at_val, discarded_at, cancelled_at} =
      case state do
        "completed" -> {completed_at, nil, nil}
        "discarded" -> {nil, completed_at, nil}
        "cancelled" -> {nil, nil, completed_at}
        _ -> {nil, nil, nil}
      end

    %Oban.Job{
      args: %{},
      worker: "Cinegraph.Workers.NoopWorker",
      queue: queue,
      state: state,
      attempted_at: attempted_at,
      completed_at: completed_at_val,
      discarded_at: discarded_at,
      cancelled_at: cancelled_at,
      attempt: if(state in ~w(executing completed discarded cancelled retryable), do: 1, else: 0),
      max_attempts: 3,
      inserted_at: minutes_ago(180),
      scheduled_at: minutes_ago(180)
    }
    |> Repo.insert!()
  end

  defp minutes_ago(n), do: DateTime.utc_now() |> DateTime.add(-n * 60, :second)

  defp restore_env(key, nil), do: Application.delete_env(:cinegraph, key)
  defp restore_env(key, value), do: Application.put_env(:cinegraph, key, value)
end
