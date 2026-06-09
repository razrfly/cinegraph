defmodule Cinegraph.Health.SurfaceAreaTest do
  @moduledoc "#1090 Phase 0 — the unified surface-area report's per-source terminal-state math."
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Health.SurfaceArea
  alias Cinegraph.Movies.{ExternalMetric, Movie}
  alias Cinegraph.Repo

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

  defp omdb_row, do: Enum.find(SurfaceArea.report().sources, &(&1.source == "omdb"))

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
      ~w(tmdb_details tmdb_metrics people_biography people_profile_path watch_providers
         now_playing omdb rotten_tomatoes metacritic canonical_lists imdb_id
         festival_person_link collaborations person_quality_scores stock_images wikidata)

    for s <- expected, do: assert(s in sources, "missing source row: #{s}")
    assert length(sources) == length(expected), "row count drifted from the §2 inventory"
  end
end
