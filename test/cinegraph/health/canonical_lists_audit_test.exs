defmodule Cinegraph.Health.CanonicalListsAuditTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Health.CanonicalListsAudit
  alias Cinegraph.Movies.{Movie, MovieList}
  alias Cinegraph.Repo

  test "flags blank never-imported IMDb lists" do
    insert_list!(source_key: "blank_list")

    audit = CanonicalListsAudit.audit()
    row = find_row(audit, "blank_list")

    assert row.blank
    assert row.never_imported
    assert row.refresh_candidate
  end

  test "flags stale nonblank lists" do
    list =
      insert_list!(
        source_key: "stale_list",
        last_import_at: days_ago(120),
        last_import_status: "success"
      )

    insert_movie!(canonical_sources: %{list.source_key => %{}})

    row = find_row(CanonicalListsAudit.audit(stale_days: 90), "stale_list")

    refute row.blank
    assert row.stale
    assert row.refresh_candidate
  end

  test "flags pending imports that are too old" do
    insert_list!(
      source_key: "old_pending",
      last_import_at: days_ago(91),
      last_import_status: "pending"
    )

    row = find_row(CanonicalListsAudit.audit(stale_days: 90), "old_pending")

    assert row.pending_too_long
  end

  test "flags below expected counts" do
    list =
      insert_list!(
        source_key: "below_expected",
        metadata: %{"expected_movie_count" => 2}
      )

    insert_movie!(canonical_sources: %{list.source_key => %{}})

    row = find_row(CanonicalListsAudit.audit(), "below_expected")

    assert row.movie_count == 1
    assert row.expected_movie_count == 2
    assert row.below_expected
  end

  test "non-IMDb active lists are reported but not refresh candidates" do
    insert_list!(
      source_key: "custom_list",
      source_type: "custom",
      source_url: "https://example.com/list"
    )

    row = find_row(CanonicalListsAudit.audit(), "custom_list")

    assert row.blank
    refute row.refresh_candidate
  end

  test "blank_only filters to blank active IMDb lists" do
    insert_list!(source_key: "blank_imdb")

    insert_list!(
      source_key: "custom_blank",
      source_type: "custom",
      source_url: "https://example.com/list"
    )

    audit = CanonicalListsAudit.audit(blank_only: true)

    assert Enum.map(audit.lists, & &1.source_key) == ["blank_imdb"]
  end

  defp find_row(audit, source_key) do
    Enum.find(audit.lists, &(&1.source_key == source_key)) ||
      flunk("missing audit row for #{source_key}")
  end

  defp insert_list!(attrs) do
    source_key = Keyword.fetch!(attrs, :source_key)

    defaults = %{
      source_key: source_key,
      name: "List #{source_key}",
      source_type: "imdb",
      source_url: "https://www.imdb.com/list/ls#{System.unique_integer([:positive])}/",
      category: "curated",
      active: true,
      metadata: %{}
    }

    attrs = Enum.into(attrs, %{})

    %MovieList{}
    |> MovieList.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_movie!(attrs) do
    attrs = Enum.into(attrs, %{})

    defaults = %{
      tmdb_id: System.unique_integer([:positive]),
      title: "Movie #{System.unique_integer([:positive])}"
    }

    %Movie{}
    |> Movie.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp days_ago(days) do
    DateTime.utc_now()
    |> DateTime.add(-days * 86_400, :second)
    |> DateTime.truncate(:second)
  end
end
