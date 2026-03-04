defmodule Cinegraph.Workers.RatingsRefreshWorkerTest do
  use Cinegraph.DataCase, async: false
  use Oban.Testing, repo: Cinegraph.Repo

  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Workers.RatingsRefreshWorker
  alias Cinegraph.Workers.OMDbEnrichmentWorker

  # Insert a minimal movie fixture with sensible defaults
  defp insert_movie(attrs) do
    defaults = %{
      tmdb_id: :rand.uniform(999_999),
      title: "Test Movie",
      import_status: "full",
      imdb_id: "tt#{:rand.uniform(9_999_999)}"
    }

    {:ok, movie} =
      %Movie{}
      |> Movie.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    movie
  end

  describe "Phase A – gap fill" do
    test "queues movies where omdb_data is nil" do
      movie = insert_movie(%{omdb_data: nil})

      RatingsRefreshWorker.new(%{}) |> Oban.insert()
      perform_job(RatingsRefreshWorker, %{})

      assert_enqueued(worker: OMDbEnrichmentWorker, args: %{"movie_id" => movie.id})
    end

    test "movies with omdb_data are only queued via Phase B (with force: true, never without)" do
      # No null movies → Phase A queues nothing, Phase B picks up the enriched movie
      Application.put_env(:cinegraph, :omdb_daily_batch_size, 1)
      movie = insert_movie(%{omdb_data: %{"Title" => "Already Enriched"}})

      perform_job(RatingsRefreshWorker, %{})

      # Must be queued with force: true (Phase B), never as a plain Phase A job
      assert_enqueued(
        worker: OMDbEnrichmentWorker,
        args: %{"movie_id" => movie.id, "force" => true}
      )
    after
      Application.delete_env(:cinegraph, :omdb_daily_batch_size)
    end

    test "skips movies without an imdb_id" do
      movie = insert_movie(%{omdb_data: nil, imdb_id: nil})

      perform_job(RatingsRefreshWorker, %{})

      refute_enqueued(worker: OMDbEnrichmentWorker, args: %{"movie_id" => movie.id})
    end

    test "skips movies with import_status other than 'full'" do
      stub = insert_movie(%{omdb_data: nil, import_status: "stub"})

      perform_job(RatingsRefreshWorker, %{})

      refute_enqueued(worker: OMDbEnrichmentWorker, args: %{"movie_id" => stub.id})
    end

    test "Phase A jobs do not include the force flag" do
      insert_movie(%{omdb_data: nil})

      perform_job(RatingsRefreshWorker, %{})

      # All enqueued jobs should lack a "force" key (Phase A)
      jobs = all_enqueued(worker: OMDbEnrichmentWorker)
      assert length(jobs) > 0
      Enum.each(jobs, fn job -> refute Map.has_key?(job.args, "force") end)
    end
  end

  describe "Phase B – stale refresh" do
    test "queues stale movies with force: true when Phase A is under batch size" do
      # One null movie (Phase A) and one already-enriched movie (Phase B candidate)
      Application.put_env(:cinegraph, :omdb_daily_batch_size, 2)

      _null_movie = insert_movie(%{omdb_data: nil})
      stale_movie = insert_movie(%{omdb_data: %{"Title" => "Stale"}})

      perform_job(RatingsRefreshWorker, %{})

      assert_enqueued(
        worker: OMDbEnrichmentWorker,
        args: %{"movie_id" => stale_movie.id, "force" => true}
      )
    after
      Application.delete_env(:cinegraph, :omdb_daily_batch_size)
    end

    test "Phase B does not run when Phase A fills the entire batch" do
      Application.put_env(:cinegraph, :omdb_daily_batch_size, 1)

      _null_movie = insert_movie(%{omdb_data: nil})
      stale_movie = insert_movie(%{omdb_data: %{"Title" => "Stale"}})

      perform_job(RatingsRefreshWorker, %{})

      refute_enqueued(
        worker: OMDbEnrichmentWorker,
        args: %{"movie_id" => stale_movie.id, "force" => true}
      )
    after
      Application.delete_env(:cinegraph, :omdb_daily_batch_size)
    end

    test "Phase B skips enriched movies without an imdb_id" do
      Application.put_env(:cinegraph, :omdb_daily_batch_size, 2)

      _null_movie = insert_movie(%{omdb_data: nil})
      no_imdb = insert_movie(%{omdb_data: %{"Title" => "No IMDb"}, imdb_id: nil})

      perform_job(RatingsRefreshWorker, %{})

      refute_enqueued(worker: OMDbEnrichmentWorker, args: %{"movie_id" => no_imdb.id})
    after
      Application.delete_env(:cinegraph, :omdb_daily_batch_size)
    end
  end
end
