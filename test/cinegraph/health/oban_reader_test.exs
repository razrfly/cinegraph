defmodule Cinegraph.Health.ObanReaderTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Health.ObanReader

  describe "configured_queues/0" do
    test "returns the queues configured for Oban" do
      queues = ObanReader.configured_queues()
      assert :tmdb in queues
      assert :omdb in queues
      assert :maintenance in queues
    end

    test "prefers known queue names captured before ProdRpc disables Oban processors" do
      previous_known = Application.get_env(:cinegraph, :known_oban_queues)
      previous_oban = Application.fetch_env!(:cinegraph, Oban)

      try do
        Application.put_env(:cinegraph, :known_oban_queues, [:tmdb, :collaboration])
        Application.put_env(:cinegraph, Oban, Keyword.merge(previous_oban, queues: []))

        assert ObanReader.configured_queues() == [:tmdb, :collaboration]
      after
        restore_env(:known_oban_queues, previous_known)
        Application.put_env(:cinegraph, Oban, previous_oban)
      end
    end

    test "falls back to Oban config when no known queue names are present" do
      previous_known = Application.get_env(:cinegraph, :known_oban_queues)

      try do
        Application.delete_env(:cinegraph, :known_oban_queues)

        queues = ObanReader.configured_queues()
        assert :tmdb in queues
        assert :omdb in queues
        assert :maintenance in queues
      after
        restore_env(:known_oban_queues, previous_known)
      end
    end
  end

  describe "counts_by_queue_and_state/2" do
    test "groups counts by queue+state" do
      insert_oban_job(queue: "tmdb", state: "available")
      insert_oban_job(queue: "tmdb", state: "available")
      insert_oban_job(queue: "tmdb", state: "executing", attempted_at: minutes_ago(1))
      insert_oban_job(queue: "omdb", state: "available")

      counts = ObanReader.counts_by_queue_and_state([:tmdb, :omdb], ["available", "executing"])
      assert get_in(counts, [:tmdb, "available"]) == 2
      assert get_in(counts, [:tmdb, "executing"]) == 1
      assert get_in(counts, [:omdb, "available"]) == 1
    end

    test "missing queue/state combos are absent (not zero)" do
      counts = ObanReader.counts_by_queue_and_state([:tmdb], ["available"])
      assert is_map(counts)
      # No jobs inserted — should be empty
      assert counts[:tmdb] == nil
    end
  end

  describe "count_completed_in/3" do
    test "counts completions in a half-open window for a specific queue" do
      now = DateTime.utc_now()
      day_start = DateTime.add(now, -3600, :second)

      insert_oban_job(
        queue: "tmdb",
        state: "completed",
        completed_at: DateTime.add(now, -1800, :second)
      )

      insert_oban_job(
        queue: "tmdb",
        state: "completed",
        completed_at: DateTime.add(now, -10, :second)
      )

      # Outside window
      insert_oban_job(
        queue: "tmdb",
        state: "completed",
        completed_at: DateTime.add(now, -86_400, :second)
      )

      assert ObanReader.count_completed_in(day_start, nil, :tmdb) == 2
    end
  end

  describe "count_failed_in/3" do
    test "counts both discarded and cancelled in window" do
      now = DateTime.utc_now()
      since = DateTime.add(now, -3600, :second)

      insert_oban_job(
        queue: "omdb",
        state: "discarded",
        completed_at: DateTime.add(now, -1800, :second)
      )

      insert_oban_job(
        queue: "omdb",
        state: "cancelled",
        completed_at: DateTime.add(now, -600, :second)
      )

      # Outside window
      insert_oban_job(
        queue: "omdb",
        state: "discarded",
        completed_at: DateTime.add(now, -86_400, :second)
      )

      assert ObanReader.count_failed_in(since, nil, :omdb) == 2
    end
  end

  describe "longest_running_seconds/1" do
    test "returns 0 when no executing jobs" do
      assert ObanReader.longest_running_seconds(:tmdb) == 0
    end

    test "returns approx elapsed seconds for the oldest executing job" do
      insert_oban_job(queue: "tmdb", state: "executing", attempted_at: minutes_ago(2))
      insert_oban_job(queue: "tmdb", state: "executing", attempted_at: minutes_ago(5))

      seconds = ObanReader.longest_running_seconds(:tmdb)
      # Oldest is 5 min ago — should be ≥ 280s (allow margin)
      assert seconds >= 280
      assert seconds <= 360
    end
  end

  defp insert_oban_job(opts) do
    queue = Keyword.fetch!(opts, :queue)
    state = Keyword.fetch!(opts, :state)
    attempted_at = Keyword.get(opts, :attempted_at)
    completed_at = Keyword.get(opts, :completed_at)

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
