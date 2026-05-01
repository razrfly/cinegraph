defmodule CinegraphWeb.PersonHelpersTest do
  use ExUnit.Case, async: true

  alias Cinegraph.Movies.Person

  import CinegraphWeb.PersonHelpers

  describe "person_slug_or_id/1" do
    test "prefers a non-empty slug" do
      assert person_slug_or_id(%Person{id: 123, slug: "vera-drew"}) == "vera-drew"
    end

    test "falls back to the id when slug is empty" do
      assert person_slug_or_id(%Person{id: 123, slug: ""}) == "123"
    end
  end
end
