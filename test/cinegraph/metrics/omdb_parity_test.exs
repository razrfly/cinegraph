defmodule Cinegraph.Metrics.OmdbParityTest do
  use Cinegraph.DataCase, async: false

  import Ecto.Query

  alias Cinegraph.Metrics
  alias Cinegraph.Metrics.OmdbParity
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Repo

  defp gap_for(label_fragment) do
    OmdbParity.gaps() |> Enum.find(&String.contains?(&1.label, label_fragment))
  end

  defp insert_movie_with_blob!(blob) do
    movie =
      %Movie{}
      |> Movie.changeset(%{
        tmdb_id: System.unique_integer([:positive]),
        title: "Parity #{System.unique_integer([:positive])}",
        imdb_id:
          "tt#{System.unique_integer([:positive]) |> rem(9_000_000) |> Kernel.+(1_000_000)}"
      })
      |> Repo.insert!()

    {1, _} = Repo.update_all(from(m in Movie, where: m.id == ^movie.id), set: [omdb_data: blob])
    %{movie | omdb_data: blob}
  end

  test "reports a gap when a blob's imdbRating was never materialized" do
    insert_movie_with_blob!(%{"Response" => "True", "imdbRating" => "7.5"})

    g = gap_for("imdbRating")
    assert g.source == 1
    assert g.dest == 0
    assert g.gap == 1
  end

  test "gap closes after store_omdb_metrics materializes the blob" do
    blob = %{"Response" => "True", "imdbRating" => "7.5"}
    movie = insert_movie_with_blob!(blob)

    assert :ok = Metrics.store_omdb_metrics(movie, blob)

    g = gap_for("imdbRating")
    assert g.source == 1
    assert g.dest == 1
    assert g.gap == 0
  end
end
