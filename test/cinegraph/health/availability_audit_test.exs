defmodule Cinegraph.Health.AvailabilityAuditTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Health.AvailabilityAudit

  alias Cinegraph.Movies.{
    Availability,
    Movie,
    WatchProvider,
    WatchProviderRegion
  }

  alias Cinegraph.Repo
  alias Cinegraph.Workers.MovieAvailabilityRefreshWorker

  test "audit/1 reports coverage, freshness, catalog, queues, examples, and commands" do
    Repo.delete_all(Oban.Job)

    normalized = insert_movie!(%{title: "Normalized Movie", tmdb_data: raw_watch_payload()})
    raw_only = insert_movie!(%{title: "Raw Only Movie", tmdb_data: raw_watch_payload()})
    default_only = insert_movie!(%{title: "Default Only Movie", tmdb_data: raw_watch_payload()})
    missing = insert_movie!(%{title: "Missing Movie"})

    assert {:ok, _} =
             Availability.store_tmdb_watch_providers(
               normalized,
               %{
                 "results" => %{
                   "US" => %{"rent" => [provider(8, "Netflix")]},
                   "GB" => %{"buy" => [provider(2, "Apple TV")]}
                 }
               },
               fetched_at: ~U[2026-01-01 00:00:00Z],
               stale_after: ~U[2026-01-31 00:00:00Z]
             )

    assert {:ok, _} =
             Availability.store_tmdb_watch_providers(
               default_only,
               %{"results" => %{"US" => %{"rent" => [provider(9, "Prime Video")]}}},
               fetched_at: ~U[2026-04-01 00:00:00Z],
               stale_after: ~U[2026-05-01 00:00:00Z]
             )

    assert {:ok, _} = Availability.record_availability_error(normalized, ["US"], "tmdb_down")

    insert_catalog!()

    %{"movie_id" => normalized.id, "force" => true}
    |> MovieAvailabilityRefreshWorker.new()
    |> Oban.insert!()

    audit = AvailabilityAudit.audit(region: "US", limit: 5, stale_days: 30)

    assert audit.region == "US"
    assert audit.summary.full_movies_with_tmdb == 4
    assert audit.summary.movies_with_raw_watch_providers == 3
    assert audit.summary.movies_with_any_normalized_availability == 2
    assert audit.summary.movies_with_region_refresh == 2
    assert audit.summary.movies_with_non_default_region_availability == 1

    assert audit.coverage.raw_tmdb_pct == 75.0
    assert audit.coverage.normalized_pct == 50.0
    assert audit.freshness.stale_refresh_rows >= 1
    assert audit.errors.current_error_rows == 1
    assert [%{error_reason: "tmdb_down", count: 1}] = audit.errors.grouped_by_reason

    assert audit.catalog.provider_count >= 1
    assert audit.catalog.region_count >= 1
    refute audit.catalog.missing_catalog

    assert get_in(audit.queues, ["Cinegraph.Workers.MovieAvailabilityRefreshWorker", "available"]) ==
             1

    assert Enum.any?(audit.examples.raw_but_not_normalized, &(&1.id == raw_only.id))

    assert Enum.any?(
             audit.examples.raw_multi_region_but_default_only_normalized,
             &(&1.id == default_only.id)
           )

    assert Enum.any?(audit.examples.missing_region_refresh, &(&1.id == raw_only.id))
    assert Enum.any?(audit.examples.missing_region_refresh, &(&1.id == missing.id))
    assert Enum.any?(audit.examples.error_refreshes, &(&1.id == normalized.id))

    assert Enum.any?(audit.recommended_commands, &String.contains?(&1, "prod.audit.availability"))
    assert Jason.encode!(audit)
  end

  defp insert_movie!(attrs) do
    defaults = %{
      tmdb_id: System.unique_integer([:positive]),
      title: "Availability Audit Movie",
      original_title: "Availability Audit Movie",
      import_status: "full",
      tmdb_data: %{}
    }

    %Movie{}
    |> Movie.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_catalog! do
    %WatchProvider{}
    |> WatchProvider.changeset(%{
      source: "tmdb",
      source_provider_id: "8",
      tmdb_provider_id: 8,
      name: "Netflix",
      last_seen_at: ~U[2026-05-01 00:00:00Z],
      active: true
    })
    |> Repo.insert!(on_conflict: :nothing)

    %WatchProviderRegion{}
    |> WatchProviderRegion.changeset(%{
      source: "tmdb",
      iso_3166_1: "US",
      english_name: "United States",
      native_name: "United States",
      last_seen_at: ~U[2026-05-01 00:00:00Z],
      active: true
    })
    |> Repo.insert!(on_conflict: :nothing)
  end

  defp raw_watch_payload do
    %{
      "watch_providers" => %{
        "results" => %{
          "US" => %{"rent" => [provider(8, "Netflix")]},
          "GB" => %{"buy" => [provider(2, "Apple TV")]}
        }
      }
    }
  end

  defp provider(id, name) do
    %{
      "provider_id" => id,
      "provider_name" => name,
      "display_priority" => id,
      "logo_path" => "/#{id}.jpg"
    }
  end
end
