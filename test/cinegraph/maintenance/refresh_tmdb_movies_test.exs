defmodule Cinegraph.Maintenance.RefreshTmdbMoviesTest do
  @moduledoc "#1106 — floor selection: the deduped union of due tmdb sources."
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Maintenance.RefreshTmdbMovies
  alias Cinegraph.Freshness.DataRefresh
  alias Cinegraph.Repo

  defp ledger!(entity_id, source, stale_after) do
    %DataRefresh{}
    |> DataRefresh.changeset(%{
      entity_type: "movie",
      entity_id: entity_id,
      source: source,
      status: "ok",
      fetched_at: DateTime.add(stale_after, -40 * 86_400, :second),
      stale_after: stale_after
    })
    |> Repo.insert!()
  end

  test "selects the deduped union of tmdb_details + watch_providers due movies" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    past = DateTime.add(now, -86_400, :second)
    future = DateTime.add(now, 86_400, :second)

    ledger!(1, "tmdb_details", past)
    ledger!(2, "watch_providers", past)
    # movie 3 is due on BOTH → must count once
    ledger!(3, "tmdb_details", past)
    ledger!(3, "watch_providers", past)
    # movie 4 not yet due → excluded
    ledger!(4, "tmdb_details", future)

    assert {:ok, %{found: 3, enqueued: 0, failed: 0, dry_run: true}} =
             RefreshTmdbMovies.run(dry_run: true)
  end
end
