defmodule CinegraphWeb.MovieLive.CollaborationHelpersTest do
  use ExUnit.Case, async: true

  alias CinegraphWeb.MovieLive.CollaborationHelpers

  describe "collaboration_search_href/1" do
    test "builds an all-people movie search URL from slugs" do
      collaboration = %{
        person_a: %{id: 1, slug: "greta-gerwig"},
        person_b: %{id: 2, slug: "saoirse-ronan"}
      }

      assert CollaborationHelpers.collaboration_search_href(collaboration) ==
               "/movies?people=greta-gerwig,saoirse-ronan&people_match=all"
    end

    test "encodes slug query values" do
      collaboration = %{
        person_a: %{id: 1, slug: "name with spaces"},
        person_b: %{id: 2, slug: "name&with=delimiters"}
      }

      assert CollaborationHelpers.collaboration_search_href(collaboration) ==
               "/movies?people=name+with+spaces,name%26with%3Ddelimiters&people_match=all"
    end

    test "falls back to ids when slugs are absent" do
      collaboration = %{
        person_a: %{id: 1, slug: nil},
        person_b: %{id: 2, slug: ""}
      }

      assert CollaborationHelpers.collaboration_search_href(collaboration) ==
               "/movies?people=1,2&people_match=all"
    end

    test "returns nil unless both people can be represented" do
      collaboration = %{
        person_a: %{id: 1, slug: "one-person"},
        person_b: %{id: nil, slug: nil}
      }

      assert CollaborationHelpers.collaboration_search_href(collaboration) == nil
    end
  end
end
