defmodule Cinegraph.Workers.MovieScoreCacheWorker do
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Cinegraph.{Repo, Movies.Movie, Movies.MovieScoreCache, Movies.MovieScoring,
                   Metrics.DisparityCalculator}

  @calculation_version "1"

  @impl true
  def perform(%Oban.Job{args: %{"movie_id" => movie_id}}) do
    movie = Repo.get!(Movie, movie_id)
    scores = MovieScoring.calculate_movie_scores(movie)
    disparity_attrs = DisparityCalculator.calculate_all(scores)

    attrs = %{
      movie_id: movie_id,
      mob_score: scores.components.mob,
      ivory_tower_score: scores.components.ivory_tower,
      industry_recognition_score: scores.components.industry_recognition,
      cultural_impact_score: scores.components.cultural_impact,
      people_quality_score: scores.components.people_quality,
      financial_performance_score: scores.components.financial_performance,
      overall_score: scores.overall_score,
      score_confidence: scores.score_confidence,
      disparity_score: disparity_attrs.disparity_score,
      disparity_category: disparity_attrs.disparity_category,
      unpredictability_score: disparity_attrs.unpredictability_score,
      calculated_at: DateTime.utc_now() |> DateTime.truncate(:second),
      calculation_version: @calculation_version
    }

    cache = Repo.get_by(MovieScoreCache, movie_id: movie_id) || %MovieScoreCache{}

    cache
    |> MovieScoreCache.changeset(attrs)
    |> Repo.insert_or_update()
    |> case do
      {:ok, _} -> :ok
      {:error, cs} -> {:error, inspect(cs.errors)}
    end
  end

  @doc """
  Enqueue score cache calculations for all movies in batches of 500.
  Run from IEx: Cinegraph.Workers.MovieScoreCacheWorker.queue_all()
  """
  def queue_all(opts \\ []) do
    batch_size = Elixir.Keyword.get(opts, :batch_size, 500)

    Movie
    |> Repo.all(select: [:id])
    |> Enum.chunk_every(batch_size)
    |> Enum.each(fn batch ->
      jobs = Enum.map(batch, fn %{id: id} -> new(%{"movie_id" => id}) end)
      Oban.insert_all(jobs)
    end)
  end
end
