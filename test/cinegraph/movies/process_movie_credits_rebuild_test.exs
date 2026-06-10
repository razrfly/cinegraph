defmodule Cinegraph.Movies.ProcessMovieCreditsRebuildTest do
  @moduledoc "#1106 — refresh-mode credits: rebuild collaborations only when the credit set changed."
  use Cinegraph.DataCase, async: false

  import Ecto.Query

  alias Cinegraph.Movies
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Repo

  defp collab_jobs do
    Repo.aggregate(
      from(j in Oban.Job, where: j.worker == "Cinegraph.Workers.CollaborationWorker"),
      :count,
      :id
    )
  end

  test "rebuild_collaborations: :if_changed enqueues a rebuild only when the credit set changes" do
    movie =
      %Movie{}
      |> Movie.changeset(%{tmdb_id: System.unique_integer([:positive]), title: "M"})
      |> Repo.insert!()

    # Director is always imported (bypasses the quality filter)
    credits = %{
      "cast" => [],
      "crew" => [
        %{
          "id" => System.unique_integer([:positive]),
          "name" => "Some Director",
          "job" => "Director",
          "department" => "Directing",
          "credit_id" => "credit-#{System.unique_integer([:positive])}"
        }
      ]
    }

    assert collab_jobs() == 0

    # first run: new credit → set changed → one rebuild enqueued
    assert :ok =
             Movies.process_movie_credits_public(movie, credits,
               rebuild_collaborations: :if_changed
             )

    assert collab_jobs() == 1

    # second run: identical credits → set unchanged → no new rebuild
    assert :ok =
             Movies.process_movie_credits_public(movie, credits,
               rebuild_collaborations: :if_changed
             )

    assert collab_jobs() == 1
  end
end
