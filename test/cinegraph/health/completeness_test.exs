defmodule Cinegraph.Health.CompletenessTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Health.{Completeness, CompletenessLog}

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
end
