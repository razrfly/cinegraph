defmodule Cinegraph.Health.YearDiscoveryTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Events.FestivalEvent
  alias Cinegraph.Health.YearDiscovery

  doctest YearDiscovery, only: [classify_error: 1]

  @worker "Cinegraph.Workers.YearDiscoveryWorker"

  describe "audit/1" do
    test "festival with no jobs in window gets label :no_runs" do
      _ev = insert_festival(source_key: "fest_a", imdb_event_id: "ev0000111")

      result = YearDiscovery.audit(days: 7)

      row = find_festival(result, "fest_a")
      assert row.label == :no_runs
      assert row.discarded == 0
      assert row.completed == 0
      assert row.imdb_event_id == "ev0000111"
      assert row.discovered_years_count == 0
    end

    test "festival with only completed jobs gets label :ok" do
      _ev = insert_festival(source_key: "fest_b", imdb_event_id: "ev0000222")

      insert_oban_job(
        source_key: "fest_b",
        state: "completed",
        completed_at: hours_ago(2)
      )

      result = YearDiscovery.audit(days: 7)
      row = find_festival(result, "fest_b")

      assert row.completed == 1
      assert row.discarded == 0
      assert row.label == :ok
      assert row.last_error == nil
    end

    test "classifies a discarded job's last error correctly" do
      _ev = insert_festival(source_key: "fest_c", imdb_event_id: "ev0000333")

      err =
        ~s|** (Oban.PerformError) #{@worker} failed with {:error, "No years found in historyEventEditions"}|

      insert_oban_job(
        source_key: "fest_c",
        state: "discarded",
        discarded_at: hours_ago(3),
        errors: [%{"at" => "2026-04-29T00:00:00Z", "attempt" => 3, "error" => err}],
        attempt: 3
      )

      result = YearDiscovery.audit(days: 7)
      row = find_festival(result, "fest_c")

      assert row.discarded == 1
      assert row.label == :source_unavailable
      assert row.last_error == err
      assert row.attempts_used == 3
    end

    test "summary aggregates counts and label rollup" do
      insert_festival(source_key: "fest_d1", imdb_event_id: "ev0000111")
      insert_festival(source_key: "fest_d2", imdb_event_id: "ev0000222")
      insert_festival(source_key: "fest_d3", imdb_event_id: "ev0000333")

      insert_oban_job(
        source_key: "fest_d1",
        state: "discarded",
        discarded_at: hours_ago(3),
        errors: [
          %{
            "at" => "2026-04-29T00:00:00Z",
            "attempt" => 3,
            "error" =>
              ~s|** (Oban.PerformError) ... failed with {:error, {:crawlbase_error, 520, "HTTP 520"}}|
          }
        ],
        attempt: 3
      )

      insert_oban_job(
        source_key: "fest_d2",
        state: "completed",
        completed_at: hours_ago(2)
      )

      # fest_d3 has no jobs

      result = YearDiscovery.audit(days: 7)

      assert result.window_days == 7
      assert result.summary.discarded >= 1
      assert result.summary.completed >= 1

      # The seeded test data may run alongside other tests sharing the
      # sandbox; assert *at least* the counts we inserted.
      assert Map.get(result.summary.by_label, :crawlbase_error, 0) >= 1
      assert Map.get(result.summary.by_label, :no_runs, 0) >= 1
    end

    test "stuck retryable jobs older than the window are excluded" do
      _ev = insert_festival(source_key: "fest_stuck", imdb_event_id: "ev0000777")

      err =
        ~s|** (Oban.PerformError) #{@worker} failed with {:error, "No __NEXT_DATA__ found"}|

      insert_oban_job(
        source_key: "fest_stuck",
        state: "retryable",
        attempted_at: days_ago(30),
        errors: [%{"at" => "2026-03-30T00:00:00Z", "attempt" => 2, "error" => err}],
        attempt: 2
      )

      result = YearDiscovery.audit(days: 7)
      row = find_festival(result, "fest_stuck")

      assert row.retryable == 0
      assert row.label == :no_runs
    end

    test "recent retryable jobs (within window) are included" do
      _ev = insert_festival(source_key: "fest_inflight", imdb_event_id: "ev0000888")

      err =
        ~s|** (Oban.PerformError) #{@worker} failed with {:error, "HTTP 502"}|

      insert_oban_job(
        source_key: "fest_inflight",
        state: "retryable",
        attempted_at: hours_ago(2),
        errors: [%{"at" => "2026-04-29T08:00:00Z", "attempt" => 1, "error" => err}],
        attempt: 1
      )

      result = YearDiscovery.audit(days: 7)
      row = find_festival(result, "fest_inflight")

      assert row.retryable == 1
    end

    test "ignores jobs outside the --days window" do
      _ev = insert_festival(source_key: "fest_e", imdb_event_id: "ev0000444")

      err =
        ~s|** (Oban.PerformError) #{@worker} failed with {:error, "No __NEXT_DATA__ found"}|

      insert_oban_job(
        source_key: "fest_e",
        state: "discarded",
        discarded_at: days_ago(10),
        errors: [%{"at" => "2026-04-19T00:00:00Z", "attempt" => 3, "error" => err}],
        attempt: 3
      )

      result = YearDiscovery.audit(days: 7)
      row = find_festival(result, "fest_e")

      # Old failure is outside the window, festival should look like no_runs
      assert row.discarded == 0
      assert row.label == :no_runs
    end

    test "festivals without an event_id are excluded" do
      insert_festival(source_key: "fest_f_with", imdb_event_id: "ev0000555")
      insert_festival(source_key: "fest_f_without", imdb_event_id: nil, source_config: %{})

      result = YearDiscovery.audit(days: 7)
      keys = Enum.map(result.festivals, & &1.source_key)

      assert "fest_f_with" in keys
      refute "fest_f_without" in keys
    end

    test "picks up event_id from source_config when imdb_event_id field is empty" do
      insert_festival(
        source_key: "fest_g",
        imdb_event_id: nil,
        source_config: %{"event_id" => "ev0000666"}
      )

      result = YearDiscovery.audit(days: 7)
      row = find_festival(result, "fest_g")

      assert row.imdb_event_id == "ev0000666"
    end
  end

  defp find_festival(%{festivals: list}, source_key) do
    Enum.find(list, &(&1.source_key == source_key)) ||
      raise "festival #{source_key} not found in audit result"
  end

  defp insert_festival(opts) do
    %FestivalEvent{}
    |> FestivalEvent.changeset(%{
      source_key: Keyword.fetch!(opts, :source_key),
      name: Keyword.get(opts, :name, "Test Festival #{Keyword.fetch!(opts, :source_key)}"),
      imdb_event_id: Keyword.get(opts, :imdb_event_id),
      source_config: Keyword.get(opts, :source_config, %{}),
      active: true,
      primary_source: "imdb"
    })
    |> Repo.insert!()
  end

  defp insert_oban_job(opts) do
    source_key = Keyword.fetch!(opts, :source_key)
    state = Keyword.fetch!(opts, :state)

    %Oban.Job{
      args: %{"source_key" => source_key},
      worker: @worker,
      queue: "scraping",
      state: state,
      attempted_at: Keyword.get(opts, :attempted_at),
      completed_at: Keyword.get(opts, :completed_at),
      discarded_at: Keyword.get(opts, :discarded_at),
      cancelled_at: Keyword.get(opts, :cancelled_at),
      errors: Keyword.get(opts, :errors, []),
      attempt: Keyword.get(opts, :attempt, 1),
      max_attempts: 3,
      inserted_at: hours_ago(24),
      scheduled_at: hours_ago(24)
    }
    |> Repo.insert!()
  end

  defp hours_ago(n), do: DateTime.utc_now() |> DateTime.add(-n * 3600, :second)
  defp days_ago(n), do: DateTime.utc_now() |> DateTime.add(-n * 86_400, :second)
end
