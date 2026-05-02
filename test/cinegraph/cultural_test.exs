defmodule Cinegraph.CulturalTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Cultural
  alias Cinegraph.Movies.{Movie, MovieList}

  describe "get_list_movies_for_movie/2" do
    test "returns normalized active movie list appearances" do
      movie =
        insert_movie!(%{
          canonical_sources: %{
            "critics_poll" => %{
              "included" => true,
              "list_position" => "12",
              "edition" => "2022",
              "scraped_title" => "Listed Movie"
            }
          }
        })

      _list =
        insert_movie_list!(%{
          source_key: "critics_poll",
          name: "Critics Poll",
          short_name: "Critics",
          slug: "critics-poll",
          category: "critics",
          icon: "eye",
          display_order: 3
        })

      assert [
               %{
                 source_key: "critics_poll",
                 list_name: "Critics Poll",
                 short_name: "Critics",
                 slug: "critics-poll",
                 category: "critics",
                 icon: "eye",
                 display_order: 3,
                 rank: 12,
                 list_year: 2022,
                 appearance_metadata: %{"scraped_title" => "Listed Movie"}
               }
             ] = Cultural.get_list_movies_for_movie(movie.id)
    end

    test "excludes inactive lists, unknown keys, and award tracking only lists" do
      movie =
        insert_movie!(%{
          canonical_sources: %{
            "active_list" => %{"included" => true},
            "inactive_list" => %{"included" => true},
            "unknown_list" => %{"included" => true},
            "award_only" => %{"included" => true}
          }
        })

      insert_movie_list!(%{source_key: "active_list", name: "Active List", slug: "active-list"})

      insert_movie_list!(%{
        source_key: "inactive_list",
        name: "Inactive List",
        slug: "inactive-list",
        active: false
      })

      insert_movie_list!(%{
        source_key: "award_only",
        name: "Award Only",
        slug: "award-only",
        category: "awards",
        tracks_awards: true
      })

      assert [%{source_key: "active_list"}] = Cultural.get_list_movies_for_movie(movie.id)
    end

    test "handles missing and unparseable rank while deriving year from list metadata" do
      movie =
        insert_movie!(%{
          canonical_sources: %{
            "unranked_list" => %{"included" => true, "list_position" => "not-a-rank"}
          }
        })

      insert_movie_list!(%{
        source_key: "unranked_list",
        name: "Unranked List",
        slug: "unranked-list",
        metadata: %{"edition" => "2024"}
      })

      assert [%{rank: nil, list_year: 2024}] = Cultural.get_list_movies_for_movie(movie.id)
    end

    test "sorts by display order, ranked status, rank, and name" do
      movie =
        insert_movie!(%{
          canonical_sources: %{
            "later" => %{"included" => true, "list_position" => 1},
            "ranked_low" => %{"included" => true, "list_position" => 20},
            "ranked_high" => %{"included" => true, "list_position" => 2},
            "unranked" => %{"included" => true}
          }
        })

      insert_movie_list!(%{source_key: "later", name: "Later", slug: "later", display_order: 3})

      insert_movie_list!(%{
        source_key: "ranked_low",
        name: "Ranked Low",
        slug: "ranked-low",
        display_order: 1
      })

      insert_movie_list!(%{
        source_key: "ranked_high",
        name: "Ranked High",
        slug: "ranked-high",
        display_order: 1
      })

      insert_movie_list!(%{
        source_key: "unranked",
        name: "Unranked",
        slug: "unranked",
        display_order: 1
      })

      assert Cultural.get_list_movies_for_movie(movie.id) |> Enum.map(& &1.source_key) == [
               "ranked_high",
               "ranked_low",
               "unranked",
               "later"
             ]
    end

    test "returns an empty list when canonical sources are empty or absent" do
      movie = insert_movie!(%{canonical_sources: %{}})

      assert Cultural.get_list_movies_for_movie(movie.id) == []
      assert Cultural.get_list_movies_for_movie(-1) == []
    end
  end

  defp insert_movie!(attrs) do
    defaults = %{
      tmdb_id: System.unique_integer([:positive]),
      title: "Cultural Test Movie #{System.unique_integer([:positive])}",
      original_title: "Cultural Test Movie",
      release_date: ~D[2020-01-01]
    }

    %Movie{}
    |> Movie.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_movie_list!(attrs) do
    source_key = Map.fetch!(attrs, :source_key)

    defaults = %{
      source_key: source_key,
      name: "Test List #{source_key}",
      source_type: "custom",
      source_url: "https://example.test/#{source_key}",
      category: "curated",
      active: true,
      tracks_awards: false,
      slug: source_key,
      display_order: 0
    }

    %MovieList{}
    |> MovieList.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end
end
