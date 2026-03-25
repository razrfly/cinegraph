defmodule Cinegraph.Movies.MovieScoringTest do
  use ExUnit.Case, async: true
  alias Cinegraph.Movies.MovieScoring

  describe "calculate_festival_recognition/1" do
    test "zero nominations returns 0.0" do
      assert MovieScoring.calculate_festival_recognition([]) == 0.0
    end

    test "multi-Oscar film scores higher than single-Sundance film" do
      multi_oscar = [["AMPAS", "Best Picture", true], ["AMPAS", "Best Director", false]]
      single_sundance = [["SFF", "Grand Jury Prize", true]]

      assert MovieScoring.calculate_festival_recognition(multi_oscar) >
               MovieScoring.calculate_festival_recognition(single_sundance)
    end

    test "returns a float in 0-10 range" do
      nominations = [["AMPAS", "Best Picture", true]]
      score = MovieScoring.calculate_festival_recognition(nominations)
      assert is_float(score)
      assert score >= 0.0 and score <= 10.0
    end
  end
end
