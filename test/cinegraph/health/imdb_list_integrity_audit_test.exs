defmodule Cinegraph.Health.ImdbListIntegrityAuditTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Health.ImdbListIntegrityAudit
  alias Cinegraph.Movies.{Movie, MovieList}
  alias Cinegraph.Repo

  test "complete list with expected count and contiguous positions is complete" do
    list = insert_list!(source_key: "complete", expected_movie_count: 3)
    insert_ranked_movies!(list.source_key, [1, 2, 3])

    row = find_row(ImdbListIntegrityAudit.audit(), "complete")

    assert row.status == "complete"
    assert row.stored_movie_count == 3
    assert row.min_position == 1
    assert row.max_position == 3
    assert row.missing_position_count == 0
  end

  test "missing middle positions reports discontinuity and gap ranges" do
    list = insert_list!(source_key: "gapped", expected_movie_count: 3)
    insert_ranked_movies!(list.source_key, [1, 3])

    row = find_row(ImdbListIntegrityAudit.audit(), "gapped")

    assert row.status == "discontinuous"
    assert row.missing_position_count == 1
    assert row.first_missing_positions == [2]
    assert row.position_gap_ranges == [%{from: 2, to: 2}]
  end

  test "count below expected with contiguous positions is partial" do
    list = insert_list!(source_key: "partial", expected_movie_count: 5)
    insert_ranked_movies!(list.source_key, [1, 2, 3])

    row = find_row(ImdbListIntegrityAudit.audit(), "partial")

    assert row.status == "partial"
    assert row.stored_movie_count == 3
    assert row.expected_movie_count == 5
    assert row.missing_position_count == 0
  end

  test "blank list is blank" do
    insert_list!(source_key: "blank", expected_movie_count: 10)

    row = find_row(ImdbListIntegrityAudit.audit(), "blank")

    assert row.status == "blank"
    assert row.stored_movie_count == 0
  end

  test "missing expected count is reported separately" do
    list = insert_list!(source_key: "unknown_expected")
    insert_ranked_movies!(list.source_key, [1, 2])

    row = find_row(ImdbListIntegrityAudit.audit(), "unknown_expected")

    assert row.status == "missing_expected_count"
    assert row.expected_movie_count == nil
  end

  test "non-numeric and missing list positions increment unranked count" do
    list = insert_list!(source_key: "unranked", expected_movie_count: 3)
    insert_movie!(canonical_sources: %{list.source_key => %{"list_position" => 1}})
    insert_movie!(canonical_sources: %{list.source_key => %{"list_position" => "not-a-rank"}})
    insert_movie!(canonical_sources: %{list.source_key => %{}})

    row = find_row(ImdbListIntegrityAudit.audit(), "unranked")

    assert row.unranked_count == 2
    assert row.distinct_positions == 1
  end

  test "duplicate positions are reported" do
    list = insert_list!(source_key: "duplicate", expected_movie_count: 2)
    insert_ranked_movies!(list.source_key, [1, 1])

    row = find_row(ImdbListIntegrityAudit.audit(), "duplicate")

    assert row.status == "discontinuous"
    assert row.duplicate_positions == [%{position: 1, count: 2}]
  end

  defp find_row(audit, source_key) do
    Enum.find(audit.lists, &(&1.source_key == source_key)) ||
      flunk("missing audit row for #{source_key}")
  end

  defp insert_ranked_movies!(source_key, positions) do
    Enum.each(positions, fn position ->
      insert_movie!(canonical_sources: %{source_key => %{"list_position" => position}})
    end)
  end

  defp insert_list!(attrs) do
    source_key = Keyword.fetch!(attrs, :source_key)
    expected = Keyword.get(attrs, :expected_movie_count)
    metadata = if expected, do: %{"expected_movie_count" => expected}, else: %{}

    defaults = %{
      source_key: source_key,
      name: "List #{source_key}",
      source_type: "imdb",
      source_url: "https://www.imdb.com/list/ls#{System.unique_integer([:positive])}/",
      category: "curated",
      active: true,
      metadata: metadata
    }

    attrs =
      attrs
      |> Keyword.drop([:expected_movie_count])
      |> Enum.into(%{})

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
end
