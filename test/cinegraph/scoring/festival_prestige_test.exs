defmodule Cinegraph.Scoring.FestivalPrestigeTest do
  use ExUnit.Case, async: true
  alias Cinegraph.Scoring.FestivalPrestige

  describe "score_nomination/3" do
    test "AMPAS Best Picture win = 110 (100 base + 10 boost)" do
      assert FestivalPrestige.score_nomination("AMPAS", "Best Picture", true) == 110.0
    end

    test "AMPAS Best Picture nom = 90 (80 + 10 boost)" do
      assert FestivalPrestige.score_nomination("AMPAS", "Best Picture", false) == 90.0
    end

    test "AMPAS Best Costume win = 100 (no boost)" do
      assert FestivalPrestige.score_nomination("AMPAS", "Best Costume", true) == 100.0
    end

    test "CFF Palme d'Or win = 95.0 (no major category match)" do
      # 'palme d\'or' doesn't contain 'picture', 'film', or 'director'
      assert FestivalPrestige.score_nomination("CFF", "Palme d'Or", true) == 95.0
    end

    test "CFF Best Film win = 105.0 (95 + 10 boost for 'film')" do
      assert FestivalPrestige.score_nomination("CFF", "Best Film", true) == 105.0
    end

    test "unknown festival win = 50.0" do
      assert FestivalPrestige.score_nomination("XYZ", "Best Short", true) == 50.0
    end

    test "unknown festival nom = 30.0" do
      assert FestivalPrestige.score_nomination("XYZ", "Best Short", false) == 30.0
    end

    test "nil category treated as empty string (no boost)" do
      assert FestivalPrestige.score_nomination("AMPAS", nil, true) == 100.0
    end
  end

  describe "score_nominations/2 — ceiling 100 (CriteriaScoring)" do
    test "empty list = 0.0" do
      assert FestivalPrestige.score_nominations([]) == 0.0
    end

    test "single Oscar Best Picture win caps at 100" do
      # 110 → capped at 100
      assert FestivalPrestige.score_nominations([["AMPAS", "Best Picture", true]]) == 100.0
    end

    test "sums multiple nominations, caps at 100" do
      # AMPAS Best Costume win (100) + HFPA nom (60) = 160 → cap 100
      assert FestivalPrestige.score_nominations([
               ["AMPAS", "Best Costume", true],
               ["HFPA", "Best Drama", false]
             ]) == 100.0
    end

    test "single minor festival win = 50.0" do
      assert FestivalPrestige.score_nominations([["XYZ", "Best Short", true]]) == 50.0
    end

    test "accepts extra tail elements in nomination tuples" do
      assert FestivalPrestige.score_nominations([["XYZ", "Best Short", true, "extra"]]) == 50.0
    end
  end

  describe "score_nomination/5 — DB score fallback" do
    test "uses DB scores when provided" do
      # DB scores override @tiers entirely
      assert FestivalPrestige.score_nomination("AMPAS", "Best Picture", true, 50.0, 30.0) ==
               60.0
    end

    test "falls back to @tiers when DB scores are nil" do
      assert FestivalPrestige.score_nomination("AMPAS", "Best Picture", true, nil, nil) == 110.0
    end

    test "category boost still applies with DB scores" do
      # win_score 50.0 + 10 boost for 'director'
      assert FestivalPrestige.score_nomination("XYZ", "Best Director", true, 50.0, 30.0) == 60.0
    end

    test "score_nominations uses DB scores from tail elements" do
      nominations = [["AMPAS", "Best Picture", true, 50.0, 30.0]]
      # 50.0 win + 10 boost = 60, ceiling 100 → 60.0
      assert FestivalPrestige.score_nominations(nominations) == 60.0
    end
  end

  describe "score_nominations/2 — algorithm regression" do
    test "sum beats max — multi-nomination film scores higher than single-nomination film" do
      # Use sub-ceiling scores: unknown festivals don't hit the 100 cap individually
      # XYZ win = 50.0, XYZ nom = 30.0; together = 80.0 > 50.0
      single = [["XYZ", "Best Short", true]]
      multi = [["XYZ", "Best Short", true], ["XYZ", "Best Documentary", false]]

      assert FestivalPrestige.score_nominations(multi) >
               FestivalPrestige.score_nominations(single)
    end
  end

  describe "score_nominations/2 — ceiling 10 (MovieScoring)" do
    test "single Oscar Best Picture win caps at 10.0" do
      assert FestivalPrestige.score_nominations([["AMPAS", "Best Picture", true]], 10.0) == 10.0
    end

    test "single minor festival win = 5.0" do
      assert FestivalPrestige.score_nominations([["XYZ", "Best Short", true]], 10.0) == 5.0
    end

    test "two Oscar nominations = 10.0 (sum 18 → cap)" do
      assert FestivalPrestige.score_nominations(
               [
                 ["AMPAS", "Best Picture", false],
                 ["AMPAS", "Best Director", false]
               ],
               10.0
             ) == 10.0
    end

    test "single unknown festival nom = 3.0" do
      assert FestivalPrestige.score_nominations([["XYZ", "Best Short", false]], 10.0) == 3.0
    end
  end
end
