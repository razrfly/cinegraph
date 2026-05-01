defmodule Cinegraph.Movies.CreditProcessingTest do
  use Cinegraph.DataCase, async: false
  use Oban.Testing, repo: Cinegraph.Repo

  alias Cinegraph.Movies
  alias Cinegraph.Movies.{Credit, Movie}
  alias Cinegraph.Workers.CollaborationWorker

  describe "process_movie_credits_public/2" do
    test "creates credits and enqueues a collaboration rebuild" do
      movie = insert_movie!()

      assert :ok = Movies.process_movie_credits_public(movie, credits_payload())

      assert Repo.aggregate(Credit, :count, :id) == 3
      assert_enqueued(worker: CollaborationWorker, args: %{"movie_id" => movie.id})
    end

    test "does not enqueue a collaboration rebuild for nil credits" do
      movie = insert_movie!()

      assert :ok = Movies.process_movie_credits_public(movie, nil)

      refute_enqueued(worker: CollaborationWorker, args: %{"movie_id" => movie.id})
    end

    test "does not enqueue a collaboration rebuild for empty credits" do
      movie = insert_movie!()

      assert :ok = Movies.process_movie_credits_public(movie, %{"cast" => [], "crew" => []})

      refute_enqueued(worker: CollaborationWorker, args: %{"movie_id" => movie.id})
    end

    test "reprocessing credits for the same movie is safe" do
      movie = insert_movie!()

      assert :ok = Movies.process_movie_credits_public(movie, credits_payload())
      assert :ok = Movies.process_movie_credits_public(movie, credits_payload())

      assert Repo.aggregate(Credit, :count, :id) == 3
      assert [_job | _] = all_enqueued(worker: CollaborationWorker)
    end
  end

  defp insert_movie! do
    %Movie{}
    |> Movie.changeset(%{
      title: "Credit Processing Movie",
      tmdb_id: System.unique_integer([:positive]),
      release_date: ~D[2020-01-01],
      import_status: "full"
    })
    |> Repo.insert!()
  end

  defp credits_payload do
    %{
      "cast" => [
        %{
          "id" => 1_001,
          "name" => "First Actor",
          "known_for_department" => "Acting",
          "popularity" => 1.0,
          "character" => "Lead",
          "order" => 0,
          "credit_id" => "cast-credit-1"
        },
        %{
          "id" => 1_002,
          "name" => "Second Actor",
          "known_for_department" => "Acting",
          "popularity" => 1.0,
          "character" => "Support",
          "order" => 1,
          "credit_id" => "cast-credit-2"
        }
      ],
      "crew" => [
        %{
          "id" => 1_003,
          "name" => "Director Person",
          "known_for_department" => "Directing",
          "job" => "Director",
          "department" => "Directing",
          "credit_id" => "crew-credit-1"
        }
      ]
    }
  end
end
