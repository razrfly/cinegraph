defmodule Cinegraph.Workers.MovieScoreCacheWorker do
  use Oban.Worker, queue: :metrics, max_attempts: 3

  import Ecto.Query

  alias Cinegraph.{
    Repo,
    Movies.Movie,
    Movies.MovieScoreCache,
    Movies.MovieScoring,
    Metrics.DisparityCalculator
  }

  @calculation_version "4"

  def current_version, do: @calculation_version

  @impl true
  def perform(%Oban.Job{args: %{"movie_id" => movie_id}}) do
    movie = Repo.get!(Movie, movie_id)
    scores = MovieScoring.calculate_movie_scores(movie)
    disparity_attrs = DisparityCalculator.calculate_all(scores)

    attrs = %{
      movie_id: movie_id,
      mob_score: scores.components.mob,
      ivory_tower_score: scores.components.ivory_tower,
      festival_recognition_score: scores.components.festival_recognition,
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

    %MovieScoreCache{}
    |> MovieScoreCache.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace, ~w[mob_score ivory_tower_score festival_recognition_score cultural_impact_score
            people_quality_score financial_performance_score overall_score score_confidence
            disparity_score disparity_category unpredictability_score
            calculated_at calculation_version updated_at]a},
      conflict_target: :movie_id
    )
    |> case do
      {:ok, _} ->
        Cinegraph.Movies.Cache.invalidate_search_results()
        :ok

      {:error, cs} ->
        {:error, inspect(cs.errors)}
    end
  end

  @doc """
  Enqueue score cache calculations for all movies in batches of 500.
  Run from IEx: Cinegraph.Workers.MovieScoreCacheWorker.queue_all()
  """
  def queue_all(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 500)

    from(m in Movie, select: m.id)
    |> Repo.all()
    |> Enum.chunk_every(batch_size)
    |> Enum.each(fn batch ->
      jobs = Enum.map(batch, fn id -> new(%{"movie_id" => id}) end)
      Oban.insert_all(jobs)
    end)
  end
end
