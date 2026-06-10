defmodule Cinegraph.Health.SurfaceAreaTest do
  @moduledoc "#1090 Phase 0 — the unified surface-area report's per-source terminal-state math."
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Health.SurfaceArea
  alias Cinegraph.Movies.{Credit, ExternalMetric, Movie, Person}
  alias Cinegraph.Repo

  # Scopes.canonical_*_count are Cachex-cached (35 min) and Cachex is not
  # sandboxed — clear it per test so canonical-scoped counts are computed fresh.
  setup do
    Cachex.clear(:health_cache)
    :ok
  end

  defp movie!(attrs) do
    %Movie{}
    |> Movie.changeset(
      Map.merge(
        %{
          tmdb_id: System.unique_integer([:positive]),
          title: "M#{System.unique_integer([:positive])}"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp set_omdb!(m, blob), do: m |> Ecto.Changeset.change(omdb_data: blob) |> Repo.update!()

  defp fetch_attempt!(m) do
    %ExternalMetric{}
    |> ExternalMetric.changeset(%{
      movie_id: m.id,
      source: "omdb",
      metric_type: "fetch_attempt",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp avail!(m, status) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Cinegraph.Movies.MovieAvailabilityRefresh{}
    |> Cinegraph.Movies.MovieAvailabilityRefresh.changeset(%{
      movie_id: m.id,
      region: "US",
      source: "tmdb",
      status: status,
      fetched_at: now,
      stale_after: DateTime.add(now, 7, :day)
    })
    |> Repo.insert!()
  end

  defp canonical_movie!(attrs \\ %{}) do
    movie!(Map.merge(%{canonical_sources: %{"1001_movies" => %{"included" => true}}}, attrs))
  end

  # a person credited on a canonical movie (so canonical_people_count includes them)
  defp canonical_person!(bio) do
    person =
      %Person{}
      |> Person.changeset(%{
        tmdb_id: System.unique_integer([:positive]),
        name: "P#{System.unique_integer([:positive])}",
        biography: bio
      })
      |> Repo.insert!()

    movie = canonical_movie!()

    %Credit{}
    |> Credit.changeset(%{
      movie_id: movie.id,
      person_id: person.id,
      credit_type: "cast",
      credit_id: "c#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()

    person
  end

  defp person_ledger!(person_id, status) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Cinegraph.Freshness.DataRefresh{}
    |> Cinegraph.Freshness.DataRefresh.changeset(%{
      entity_type: "person",
      entity_id: person_id,
      source: "tmdb_person",
      status: status,
      fetched_at: now,
      stale_after: DateTime.add(now, 30, :day)
    })
    |> Repo.insert!()
  end

  defp row_for(source), do: Enum.find(SurfaceArea.report().sources, &(&1.source == source))
  defp omdb_row, do: row_for("omdb")

  test "OMDb row partitions eligible into fetched / source_absent / needs_fetch" do
    # fetched
    movie!(%{imdb_id: "tt1"}) |> set_omdb!(%{"Response" => "True"})
    # source-absent (tried)
    movie!(%{imdb_id: "tt2"}) |> fetch_attempt!()
    # needs-fetch
    movie!(%{imdb_id: "tt3"})
    # ineligible (no imdb_id)
    movie!(%{imdb_id: nil})

    row = omdb_row()

    assert row.kind == :fetch
    assert row.eligible == 3
    assert row.fetched == 1
    assert row.needs_fetch == 1
    assert row.source_absent == 1
    # (fetched + source_absent) / eligible = 2/3
    assert row.terminal_pct == 66.67
  end

  test "watch_providers headlines the canonical subset (#1101 WS2)" do
    # canonical movies are the headline denominator (not the 914k full catalog)
    a = canonical_movie!(%{import_status: "full"})
    avail!(a, "success")
    b = canonical_movie!(%{import_status: "full"})
    avail!(b, "no_results")
    _c = canonical_movie!(%{import_status: "full"})

    row = row_for("watch_providers")
    assert row.eligible == 3
    assert row.fetched == 1
    assert row.source_absent == 1
    assert row.needs_fetch == 1
    assert row.target == 95.0
  end

  test "fetch rows carry homeostasis targets; biography is now terminalizable (#1101 WS1)" do
    assert omdb_row().target == 99.5
    assert row_for("people_profile_path").target == 99.5
    # biography now has a terminal target (the substrate makes it terminalizable)
    assert row_for("people_biography").target == 99.5
    # budget/revenue are derived/ceiling rows — no terminal%/target
    assert row_for("tmdb_budget").kind == :derived
    assert row_for("tmdb_budget").terminal_pct == nil
  end

  test "people_biography counts fetched-but-blank (a tmdb_person ledger attempt) as source-absent/terminal (#1101 WS1)" do
    # covered: canonical person with a bio
    canonical_person!("a real biography")
    # source-absent: canonical person, blank bio, but a tmdb_person ledger attempt
    attempted = canonical_person!(nil)
    person_ledger!(attempted.id, "ok")
    # needs-fetch: canonical person, blank bio, no ledger attempt
    canonical_person!(nil)

    row = row_for("people_biography")
    assert row.eligible == 3
    assert row.fetched == 1
    assert row.source_absent == 1
    assert row.needs_fetch == 1
    # terminal = (covered + source-absent) / eligible = 2/3
    assert row.terminal_pct == 66.67
  end

  test "festival_person_link counts only person-tracked categories (film-only excluded)" do
    # linked person-tracked nomination → fetched
    linked = Cinegraph.FestivalFixtures.plant_nomination!(tracks_person: true)
    linked.nom |> Ecto.Changeset.change(person_id: linked.person.id) |> Repo.update!()
    # unlinked person-tracked (person_id nil by default) → eligible, not fetched
    _unlinked = Cinegraph.FestivalFixtures.plant_nomination!(tracks_person: true)
    # film-only category → must NOT count as a failed person link
    _film_only = Cinegraph.FestivalFixtures.plant_nomination!(tracks_person: false)

    row = row_for("festival_person_link")
    assert row.eligible == 2
    assert row.fetched == 1
    assert row.needs_fetch == 1
    assert row.target == 95.0
  end

  test "computed/supplemental sources carry no coverage number" do
    sources = SurfaceArea.report().sources
    collab = Enum.find(sources, &(&1.source == "collaborations"))
    wiki = Enum.find(sources, &(&1.source == "wikidata"))

    assert collab.kind == :computed
    assert collab.terminal_pct == nil
    assert wiki.kind == :supplemental
    assert wiki.eligible == nil
  end

  test "every §2 source family is present (catches inventory drift)" do
    sources = SurfaceArea.report().sources |> Enum.map(& &1.source)

    # One row per §2 inventory family (#1090 §2) — keep in sync if a source is added.
    expected =
      ~w(tmdb_details tmdb_metrics tmdb_budget tmdb_revenue people_biography people_profile_path
         watch_providers now_playing omdb rotten_tomatoes metacritic canonical_lists imdb_id
         festival_person_link collaborations person_quality_scores stock_images wikidata)

    for s <- expected, do: assert(s in sources, "missing source row: #{s}")
    assert length(sources) == length(expected), "row count drifted from the §2 inventory"
  end
end
