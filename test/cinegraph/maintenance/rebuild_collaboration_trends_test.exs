defmodule Cinegraph.Maintenance.RebuildCollaborationTrendsTest do
  @moduledoc """
  Verifies `RebuildCollaborationTrends.view_sql/0` semantics on known seed data —
  in particular that rating/revenue are NOT inflated by the `movie_genres` join or
  by multiple collaborations on the same movie (GitHub #1019), and that
  `new_collaborators` reflects first-year-of-collaboration.

  Runs `view_sql/0` as a subquery against the seeded base tables, so it exercises
  the exact production SQL without any materialized-view DDL.
  """
  use Cinegraph.DataCase, async: true

  alias Cinegraph.Maintenance.RebuildCollaborationTrends, as: Rebuild
  alias Cinegraph.Repo

  describe "view_sql/0 aggregation" do
    test "dedups genres and co-stars per movie; computes new_collaborators by first year" do
      # People
      p1 = mk_person("P1", 9_000_001)
      p2 = mk_person("P2", 9_000_002)
      p3 = mk_person("P3", 9_000_003)
      p4 = mk_person("P4", 9_000_004)

      # Genres
      g1 = mk_genre("G1", 9_100_001)
      g2 = mk_genre("G2", 9_100_002)

      # Movies (rating, revenue)
      m1 = mk_movie("M1", 9_200_001)
      m2 = mk_movie("M2", 9_200_002)
      m3 = mk_movie("M3", 9_200_003)

      # `collaborations` holds ONE row per unordered pair; movies they did together
      # are multiple `collaboration_details` under that row.
      c_p1_p2 = mk_collab(p1, p2)
      c_p1_p3 = mk_collab(p1, p3)
      c_p1_p4 = mk_collab(p1, p4)

      # M1 (2000): rating 9.0, revenue 100, TWO genres, and P1 worked on it with TWO
      # co-stars (P2 and P4) — exercises both the genre fan-out and the co-star fan-out.
      mk_movie_genre(m1, g1)
      mk_movie_genre(m1, g2)
      mk_detail(c_p1_p2, m1, 2000, "9.0", 100)
      mk_detail(c_p1_p4, m1, 2000, "9.0", 100)

      # M2 (2000): rating 6.0, revenue 50, ONE genre, P1+P3.
      mk_movie_genre(m2, g1)
      mk_detail(c_p1_p3, m2, 2000, "6.0", 50)

      # M3 (2001): rating 4.0, revenue 200, ONE genre — same P1+P2 collaboration,
      # a new detail (P2 is NOT a new collaborator in 2001).
      mk_movie_genre(m3, g2)
      mk_detail(c_p1_p2, m3, 2001, "4.0", 200)

      [y2000, y2001] = trends_for(p1)

      # --- 2000 ---
      assert y2000["year"] == 2000
      # P1 worked with P2, P3, P4 — all first met in 2000.
      assert y2000["unique_collaborators"] == 3
      assert y2000["new_collaborators"] == 3
      # Distinct movies that year: M1, M2 (NOT inflated by genres/co-stars).
      assert y2000["total_collaborations"] == 2
      # Correct avg over distinct movies: (9.0 + 6.0) / 2 = 7.5.
      # The old genre/co-star fan-out would have produced 8.4.
      assert Decimal.equal?(y2000["avg_rating"], Decimal.new("7.5"))
      # Correct revenue: 100 + 50 = 150 (old fan-out would give 450).
      assert Decimal.equal?(to_decimal(y2000["total_revenue"]), Decimal.new("150"))
      # Distinct genres across M1 {G1,G2} and M2 {G1}.
      assert Enum.sort(y2000["genre_ids"]) == Enum.sort([g1, g2])

      # --- 2001 ---
      assert y2001["year"] == 2001
      assert y2001["unique_collaborators"] == 1
      assert y2001["new_collaborators"] == 0
      assert y2001["total_collaborations"] == 1
      assert Decimal.equal?(y2001["avg_rating"], Decimal.new("4.0"))
      assert Decimal.equal?(to_decimal(y2001["total_revenue"]), Decimal.new("200"))
      assert y2001["genre_ids"] == [g2]
    end

    test "counts a new collaborator from both perspectives" do
      p1 = mk_person("A", 9_000_011)
      p2 = mk_person("B", 9_000_012)
      m1 = mk_movie("X", 9_200_011)
      mk_detail(mk_collab(p1, p2), m1, 1999, "5.0", 10)

      assert [%{"new_collaborators" => 1, "unique_collaborators" => 1}] = trends_for(p1)
      assert [%{"new_collaborators" => 1, "unique_collaborators" => 1}] = trends_for(p2)
    end
  end

  ## --- helpers ---

  defp trends_for(person_id) do
    %{rows: rows, columns: cols} =
      Repo.query!(
        "SELECT * FROM (#{Rebuild.view_sql()}) t WHERE person_id = $1 ORDER BY year",
        [person_id]
      )

    Enum.map(rows, fn row -> cols |> Enum.zip(row) |> Map.new() end)
  end

  defp mk_person(name, tmdb_id),
    do:
      one(
        "INSERT INTO people (tmdb_id, name, inserted_at, updated_at) VALUES ($1, $2, now(), now()) RETURNING id",
        [tmdb_id, name]
      )

  defp mk_movie(title, tmdb_id),
    do:
      one(
        "INSERT INTO movies (tmdb_id, title, inserted_at, updated_at) VALUES ($1, $2, now(), now()) RETURNING id",
        [tmdb_id, title]
      )

  defp mk_genre(name, tmdb_id),
    do:
      one(
        "INSERT INTO genres (tmdb_id, name, inserted_at, updated_at) VALUES ($1, $2, now(), now()) RETURNING id",
        [tmdb_id, name]
      )

  defp mk_collab(a, b),
    do:
      one(
        "INSERT INTO collaborations (person_a_id, person_b_id, inserted_at, updated_at) VALUES ($1, $2, now(), now()) RETURNING id",
        [a, b]
      )

  defp mk_detail(collab_id, movie_id, year, rating, revenue),
    do:
      Repo.query!(
        "INSERT INTO collaboration_details (collaboration_id, movie_id, collaboration_type, year, movie_rating, movie_revenue) VALUES ($1, $2, $3, $4, $5, $6)",
        [collab_id, movie_id, "acting", year, Decimal.new(rating), revenue]
      )

  defp mk_movie_genre(movie_id, genre_id),
    do:
      Repo.query!("INSERT INTO movie_genres (movie_id, genre_id) VALUES ($1, $2)", [
        movie_id,
        genre_id
      ])

  defp one(sql, params), do: Repo.query!(sql, params).rows |> hd() |> hd()

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
end
