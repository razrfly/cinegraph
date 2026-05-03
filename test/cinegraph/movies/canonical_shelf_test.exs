defmodule Cinegraph.Movies.CanonicalShelfTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Movies
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Repo

  test "list_canonical_shelf_movies/2 orders by canonical list position" do
    later = insert_movie!("Later", "cult_movies_400", 9)
    earlier = insert_movie!("Earlier", "cult_movies_400", 1)
    _other = insert_movie!("Other", "1001_movies", 1)

    assert [earlier.id, later.id] ==
             "cult_movies_400"
             |> Movies.list_canonical_shelf_movies(10)
             |> Enum.map(& &1.id)
  end

  defp insert_movie!(title, source_key, position) do
    attrs = %{
      tmdb_id: System.unique_integer([:positive]),
      title: title,
      original_title: title,
      release_date: ~D[1984-01-01],
      import_status: "full",
      canonical_sources: %{
        source_key => %{
          "included" => true,
          "list_position" => position
        }
      }
    }

    %Movie{}
    |> Movie.changeset(attrs)
    |> Repo.insert!()
  end
end
