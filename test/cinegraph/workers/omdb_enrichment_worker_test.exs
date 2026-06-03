defmodule Cinegraph.Workers.OMDbEnrichmentWorkerTest do
  use Cinegraph.DataCase, async: false

  import Ecto.Query

  alias Cinegraph.Movies.{ExternalMetric, Movie}
  alias Cinegraph.Repo
  alias Cinegraph.Services.OMDb.ClientStub
  alias Cinegraph.Workers.OMDbEnrichmentWorker

  # Swap the OMDb HTTP client for a stub so no live API calls are made.
  setup do
    previous_client = Application.fetch_env(:cinegraph, :omdb_http_client)
    Application.put_env(:cinegraph, :omdb_http_client, ClientStub)
    ClientStub.reset()

    on_exit(fn ->
      ClientStub.reset()

      case previous_client do
        {:ok, client} -> Application.put_env(:cinegraph, :omdb_http_client, client)
        :error -> Application.delete_env(:cinegraph, :omdb_http_client)
      end
    end)

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

  # --- skip guard (#1053: terminal test is blob presence, not an omdb row) ---

  describe "skip guard" do
    test "does not call OMDb when movie already has an omdb_data blob" do
      movie = insert_movie!()

      # #1053: a stored blob is the "already fetched" signal. No external_metrics
      # row is needed — a sparse OMDb response may have materialized only an
      # `imdb` row (or none). Seed JUST the blob.
      Repo.update_all(from(m in Movie, where: m.id == ^movie.id),
        set: [omdb_data: %{"Response" => "True", "Title" => "Already Enriched"}]
      )

      # Stub will blow up if actually called — but it won't be
      ClientStub.put_response({:error, "should not be called"})

      assert {:ok, _} = run_worker(movie.id)
      assert metric_count(movie.id) == 0
    end

    test "force_refresh re-fetches even when a blob is present" do
      movie = insert_movie!()

      Repo.update_all(from(m in Movie, where: m.id == ^movie.id),
        set: [omdb_data: %{"Response" => "True", "Title" => "Stale"}]
      )

      ClientStub.put_response({:ok, %{"Response" => "True", "imdbRating" => "8.1"}})

      assert {:ok, _} = run_worker(movie.id, true)
      # The forced fetch materialized the imdbRating into imdb/rating_average.
      assert has_metric?(movie.id, "imdb", "rating_average")
    end
  end

  # --- #1053 4.0: atomic blob + metrics write ----------------------------

  describe "atomic store (#1053)" do
    test "a successful fetch commits BOTH the omdb_data blob and the derived metrics" do
      movie = insert_movie!()

      ClientStub.put_response(
        {:ok,
         %{
           "Response" => "True",
           "Title" => "Rich",
           "imdbRating" => "7.5",
           "imdbVotes" => "1,234",
           "Metascore" => "82",
           "Awards" => "Won 1 Oscar.",
           "Rated" => "PG-13",
           "BoxOffice" => "$1,000,000",
           "Ratings" => [%{"Source" => "Rotten Tomatoes", "Value" => "91%"}]
         }}
      )

      assert {:ok, _} = run_worker(movie.id)

      # Blob committed (opt back in to load_in_query: false field).
      reloaded =
        Repo.one(
          from m in Movie, where: m.id == ^movie.id, select_merge: %{omdb_data: m.omdb_data}
        )

      assert reloaded.omdb_data["Response"] == "True"

      # All derived metric families committed in the same transaction. Note
      # OMDb's imdbRating lands under the `imdb` source, not `omdb`.
      assert has_metric?(movie.id, "imdb", "rating_average")
      assert has_metric?(movie.id, "imdb", "rating_votes")
      assert has_metric?(movie.id, "metacritic", "metascore")
      assert has_metric?(movie.id, "omdb", "awards_summary")
      assert has_metric?(movie.id, "omdb", "content_rating")
      assert has_metric?(movie.id, "rotten_tomatoes", "tomatometer")
    end
  end

  # --- #1053 4.2: snooze on quota exhaustion -----------------------------

  describe "quota exhaustion" do
    test "snoozes (does not discard) when OMDb returns 'Request limit reached!'" do
      movie = insert_movie!()
      ClientStub.put_response({:error, "Request limit reached!"})

      assert {:snooze, 3600} = run_worker(movie.id)

      # A snooze must NOT record a fetch_attempt — the movie isn't source-absent,
      # we just hit the daily cap and will retry.
      refute fetch_attempt_for(movie.id)
      assert metric_count(movie.id) == 0
    end
  end

  defp metric_count(movie_id) do
    Repo.aggregate(from(em in ExternalMetric, where: em.movie_id == ^movie_id), :count, :id)
  end

  defp has_metric?(movie_id, source, metric_type) do
    Repo.exists?(
      from em in ExternalMetric,
        where:
          em.movie_id == ^movie_id and em.source == ^source and em.metric_type == ^metric_type
    )
  end
end
