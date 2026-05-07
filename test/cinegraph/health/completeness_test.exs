defmodule Cinegraph.Health.CompletenessTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Health.{Completeness, CompletenessLog}
  alias Cinegraph.Movies.{Credit, Movie, Person}

  setup do
    Cachex.clear(:health_cache)
    :ok
  end

  describe "run/0" do
    test "returns a snapshot with movie/people/festival blocks and overall pct" do
      snapshot = Completeness.run()

      assert %{
               generated_at: %DateTime{},
               movies: %{
                 total: _,
                 with_omdb: _,
                 with_omdb_pct: _,
                 with_imdb_id: _,
                 with_imdb_id_pct: _
               },
               people: %{
                 total: _,
                 with_profile: _,
                 with_profile_pct: _,
                 with_biography: _,
                 with_biography_pct: _,
                 with_known_for: _,
                 with_known_for_pct: _
               },
               festivals: %{ceremonies: _, nominations: _, with_movie_pct: _},
               overall_completeness_pct: overall
             } = snapshot

      assert is_float(overall) and overall >= 0.0 and overall <= 100.0
    end

    test "movies and people totals are scoped to the canonical-list catalog (#896 Phase 1.5)" do
      # Canonical movie + person on it — both should be counted
      canonical = insert_movie!(canonical: true, imdb_id: "tt0111161")
      person = insert_person!(%{tmdb_id: 900, name: "Counted"})
      insert_credit!(person, canonical)

      # Long-tail bulk-import data — should be excluded
      _bulk_movie = insert_movie!(canonical: false, imdb_id: nil)
      bulk_person = insert_person!(%{tmdb_id: 901, name: "Excluded", profile_path: nil})
      bulk_credit_movie = insert_movie!(canonical: false)
      insert_credit!(bulk_person, bulk_credit_movie)

      snapshot = Completeness.run()

      assert snapshot.movies.total == 1
      assert snapshot.people.total == 1
      assert snapshot.movies.with_imdb_id == 1
    end
  end

  describe "run_and_persist/0" do
    test "inserts a completeness_log row keyed by today's UTC date" do
      assert {:ok, %CompletenessLog{captured_on: date, payload: payload}} =
               Completeness.run_and_persist()

      assert date == Date.utc_today()
      assert is_map(payload)
      assert is_number(payload["overall_completeness_pct"])
    end

    test "upserts on captured_on (re-running same day replaces payload)" do
      {:ok, _} = Completeness.run_and_persist()
      {:ok, second} = Completeness.run_and_persist()

      # Only one row total
      total = Repo.aggregate(CompletenessLog, :count, :captured_on)
      assert total == 1
      assert second.captured_on == Date.utc_today()
    end
  end

  describe "history/1" do
    test "returns rows in ascending captured_on order" do
      d2 = Date.add(Date.utc_today(), -2)
      d1 = Date.add(Date.utc_today(), -1)
      d0 = Date.utc_today()

      Enum.each([d2, d1, d0], fn date ->
        %CompletenessLog{}
        |> CompletenessLog.changeset(%{captured_on: date, payload: %{"x" => 1}})
        |> Repo.insert!()
      end)

      rows = Completeness.history(7)
      assert Enum.map(rows, & &1.captured_on) == [d2, d1, d0]
    end
  end

  defp insert_person!(attrs) do
    %Person{}
    |> Person.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_movie!(opts) do
    canonical = Keyword.get(opts, :canonical, false)
    canonical_sources = if canonical, do: %{"1001_movies" => %{"included" => true}}, else: %{}

    attrs =
      %{
        tmdb_id: System.unique_integer([:positive]),
        title: "Movie #{System.unique_integer([:positive])}",
        canonical_sources: canonical_sources
      }
      |> Map.merge(Map.new(Keyword.take(opts, [:imdb_id])))

    %Movie{}
    |> Movie.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_credit!(person, movie) do
    %Credit{}
    |> Credit.changeset(%{
      movie_id: movie.id,
      person_id: person.id,
      credit_type: "cast",
      character: "Self",
      cast_order: 0,
      credit_id: "credit-#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end
end
