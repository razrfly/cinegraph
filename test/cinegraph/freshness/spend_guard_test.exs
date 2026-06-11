defmodule Cinegraph.Freshness.SpendGuardTest do
  @moduledoc "#1108 §4 — lightweight read-through spend-guard."
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Freshness.SpendGuard
  alias Cinegraph.Repo

  setup do
    # Cachex is not sandboxed — start each test with cold spend-guard memo.
    Cachex.clear(:health_cache)

    prev = %{
      enabled: Application.get_env(:cinegraph, :read_through_enabled),
      caps: Application.get_env(:cinegraph, :read_through_daily_caps),
      limit: Application.get_env(:cinegraph, :read_through_queue_limit)
    }

    on_exit(fn ->
      put(:read_through_enabled, prev.enabled)
      put(:read_through_daily_caps, prev.caps)
      put(:read_through_queue_limit, prev.limit)
    end)

    :ok
  end

  defp put(k, v), do: Application.put_env(:cinegraph, k, v)

  defp job!(attrs) do
    now = DateTime.utc_now()

    %Oban.Job{}
    |> Ecto.Changeset.change(
      Map.merge(
        %{worker: "T", queue: "tmdb", args: %{}, inserted_at: now, scheduled_at: now},
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp enable!(opts \\ []) do
    put(:read_through_enabled, true)
    put(:read_through_daily_caps, Keyword.get(opts, :caps, %{tmdb: 40_000, omdb: 90_000}))
    put(:read_through_queue_limit, Keyword.get(opts, :limit, 1_000))
    Cachex.clear(:health_cache)
  end

  test "denied when the master flag is off (default)" do
    put(:read_through_enabled, false)
    refute SpendGuard.allow?(:tmdb_details)
  end

  test "denied for an unknown source even when enabled" do
    enable!()
    refute SpendGuard.allow?(:bogus)
  end

  test "allowed when enabled, under cap, low queue depth" do
    enable!()
    assert SpendGuard.allow?(:tmdb_details)
    assert SpendGuard.allow?(:omdb)
  end

  test "denied when the queue is at/over its daily cap" do
    enable!(caps: %{tmdb: 2})
    job!(%{state: "completed", completed_at: DateTime.utc_now()})
    job!(%{state: "completed", completed_at: DateTime.utc_now()})

    refute SpendGuard.allow?(:tmdb_details)
  end

  test "denied when the queue is backpressured (depth over limit)" do
    enable!(limit: 0)
    job!(%{state: "available"})

    refute SpendGuard.allow?(:tmdb_details)
  end

  test "memoizes for 30s — a DB change within the window does not flip the verdict" do
    enable!(caps: %{tmdb: 2})
    # cold: 0 completed → allowed (this caches count=0)
    assert SpendGuard.allow?(:tmdb_details)

    # push over cap, but the cached count is stale within the 30s window
    job!(%{state: "completed", completed_at: DateTime.utc_now()})
    job!(%{state: "completed", completed_at: DateTime.utc_now()})
    assert SpendGuard.allow?(:tmdb_details)

    # after the memo is cleared, the cap is enforced
    Cachex.clear(:health_cache)
    refute SpendGuard.allow?(:tmdb_details)
  end
end
