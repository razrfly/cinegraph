defmodule Cinegraph.Movies.MovieListsTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Movies.MovieLists

  describe "seed_default_lists/0" do
    test "seeds the cult movies IMDb list as a production-importable source" do
      assert %{errors: [], total: total} = MovieLists.seed_default_lists()
      assert total >= 10

      assert list = MovieLists.get_active_by_source_key("cult_movies_400")
      assert list.name == "400 Greatest Cult Movies"
      assert list.source_type == "imdb"
      assert list.source_url == "https://www.imdb.com/list/ls053182933/"
      assert list.source_id == "ls053182933"
      assert list.category == "curated"
      assert list.slug == "cult-movies-400"
      assert list.short_name == "Cult Movies"
      assert list.icon == "sparkles"
      assert list.display_order == 10
      assert list.tracks_awards == false

      assert list.metadata["source"] == "IMDb user list"
      assert list.metadata["use"] == "broad cult candidate pool"
      assert list.metadata["issue"] == "857"
      # cult is the recommendation rail (#1038 2b) — /algorithms renders it in rail mode
      assert list.metadata["rail"] == true
      assert is_binary(list.metadata["rail_thesis"])

      assert MovieLists.all_as_config()["cult_movies_400"] == %{
               list_id: "ls053182933",
               source_key: "cult_movies_400",
               name: "400 Greatest Cult Movies",
               category: "curated",
               metadata: list.metadata
             }
    end
  end
end
