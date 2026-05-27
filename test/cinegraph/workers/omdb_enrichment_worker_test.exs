defmodule Cinegraph.Workers.OMDbEnrichmentWorkerTest do
  use Cinegraph.DataCase, async: false

  import Ecto.Query

  alias Cinegraph.Movies.{ExternalMetric, Movie}
  alias Cinegraph.Repo
  alias Cinegraph.Services.OMDb.ClientStub
  alias Cinegraph.Workers.OMDbEnrichmentWorker

  # Swap the OMDb HTTP client for a stub so no live API calls are made.
  setup do
    Application.put_env(:cinegraph, :omdb_http_client, ClientStub)
    on_exit(fn -> Application.delete_env(:cinegraph, :omdb_http_client) end)
    :ok
  end

  # --- helpers -----------------------------------------------------------

  defp insert_movie!(attrs \\ %{}) do
    defaults = %{
      tmdb_id: System.unique_integer([:positive]),
      title: "Test Movie #{System.unique_integer([:positive])}",
      imdb_id: "tt#{System.unique_integer([:positive]) |> rem(9_000_000) |> Kernel.+(1_000_000)}"
    }

    %Movie{}
    |> Movie.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp run_worker(movie_id, force \\ false) do
    args =
      if force, do: %{"movie_id" => movie_id, "force" => true}, else: %{"movie_id" => movie_id}

    OMDbEnrichmentWorker.perform(%Oban.Job{args: args})
  end

  defp fetch_attempt_for(movie_id) do
    Repo.one(
      from em in ExternalMetric,
        where:
          em.movie_id == ^movie_id and
            em.source == "omdb" and
            em.metric_type == "fetch_attempt"
    )
  end

  # --- "Movie not found!" regression (#993) ------------------------------

  describe "Movie not found! response" do
    setup do
      ClientStub.put_response({:error, "Movie not found!"})
    end

    test "records a fetch_attempt metric so the movie exits the sweeper backlog" do
      movie = insert_movie!()

      assert :ok = run_worker(movie.id)

      assert %ExternalMetric{
               text_value: "Movie not found!",
               source: "omdb",
               metric_type: "fetch_attempt"
             } =
               fetch_attempt_for(movie.id)
    end

    test "returns :ok (no Oban retry) even though OMDb has no data" do
      movie = insert_movie!()
      assert :ok = run_worker(movie.id)
    end
  end

  # --- other handled error reasons ---------------------------------------

  describe "known-unavailable error reasons" do
    test "records fetch_attempt for 'Error getting data.'" do
      ClientStub.put_response({:error, "Error getting data."})
      movie = insert_movie!()

      assert :ok = run_worker(movie.id)
      assert fetch_attempt_for(movie.id)
    end

    test "records fetch_attempt for 'Incorrect IMDb ID.'" do
      ClientStub.put_response({:error, "Incorrect IMDb ID."})
      movie = insert_movie!()

      assert :ok = run_worker(movie.id)
      assert fetch_attempt_for(movie.id)
    end
  end

  # --- skip guard --------------------------------------------------------

  describe "skip guard" do
    test "does not call OMDb when movie already has omdb_data and an external_metrics row" do
      movie = insert_movie!()

      # Pre-populate both the JSONB field and an external_metrics row
      Repo.update_all(from(m in Movie, where: m.id == ^movie.id),
        set: [omdb_data: %{"Title" => "Already Enriched"}]
      )

      %ExternalMetric{}
      |> ExternalMetric.changeset(%{
        movie_id: movie.id,
        source: "omdb",
        metric_type: "rating_average",
        value: 7.5,
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

      # Stub will blow up if actually called — but it won't be
      ClientStub.put_response({:error, "should not be called"})

      assert {:ok, _} = run_worker(movie.id)
    end
  end
end
