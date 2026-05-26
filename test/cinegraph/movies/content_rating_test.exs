defmodule Cinegraph.Movies.ContentRatingTest do
  use ExUnit.Case, async: true

  alias Cinegraph.Movies.ContentRating

  describe "to_min_age/2" do
    test "normalizes MPAA certifications" do
      assert ContentRating.to_min_age("G", "US") == 0
      assert ContentRating.to_min_age("Rated PG-13", "US") == 13
      assert ContentRating.to_min_age("R", "US") == 17
      assert ContentRating.to_min_age("NC-17", "US") == 18
    end

    test "normalizes BBFC and FSK certifications" do
      assert ContentRating.to_min_age("12A", "GB") == 12
      assert ContentRating.to_min_age("16", "DE") == 16
    end

    test "leaves unrated or unknown labels unknown" do
      assert ContentRating.to_min_age("NR", "US") == nil
      assert ContentRating.to_min_age("Unrated", "US") == nil
      assert ContentRating.to_min_age(nil, "US") == nil
    end
  end

  describe "certifications_for_max_age/2" do
    test "returns certifications up to the supplied age" do
      assert ContentRating.certifications_for_max_age("US", 12) == ["G", "PG"]
      assert ContentRating.certifications_for_max_age("US", 16) == ["G", "PG", "PG-13"]

      assert ContentRating.certifications_for_max_age("US", 99) == [
               "G",
               "NC-17",
               "PG",
               "PG-13",
               "R"
             ]
    end
  end
end
