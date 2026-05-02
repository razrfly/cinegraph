defmodule Cinegraph.Movies.RefreshTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Movies.{Movie, Refresh}
  alias Cinegraph.Repo

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  test "enqueue_movie_external_refresh/2 enqueues selected external refresh jobs only" do
    movie = insert_movie!()

    assert {:ok, queued} =
             Refresh.enqueue_movie_external_refresh(movie.id,
               tmdb: true,
               omdb: false,
               availability: true,
               regions: ["US"],
               force: true
             )

    assert queued == [:tmdb, :availability]

    jobs = Repo.all(Oban.Job)

    assert Enum.map(jobs, & &1.worker) |> Enum.sort() == [
             "Cinegraph.Workers.MovieAvailabilityRefreshWorker",
             "Cinegraph.Workers.TMDbDetailsWorker"
           ]
  end

  test "enqueue_movie_external_refresh/2 fails fast for a missing movie" do
    assert {:error, :movie_not_found} =
             Refresh.enqueue_movie_external_refresh(-1, omdb: true, availability: true)

    assert Repo.aggregate(Oban.Job, :count, :id) == 0
  end

  defp insert_movie! do
    %Movie{}
    |> Movie.changeset(%{
      tmdb_id: System.unique_integer([:positive]),
      title: "External Refresh Movie",
      original_title: "External Refresh Movie",
      import_status: "full"
    })
    |> Repo.insert!()
  end
end
