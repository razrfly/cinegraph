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
  def perform(%Oban.Job{args: %{"movie_id" => movie_id} = args}) do
    skip_cache_invalidation = Map.get(args, "skip_cache_invalidation", false)

    movie = Repo.get!(Movie, movie_id)
    scores = MovieScoring.calculate_movie_scores(movie)
    disparity_attrs = DisparityCalculator.calculate_all(scores)

    attrs = %{
      movie_id: movie_id,
      mob_score: scores.components.mob || 0.0,
      critics_score: scores.components.critics || 0.0,
      festival_recognition_score: scores.components.festival_recognition,
      time_machine_score: scores.components.time_machine,
      auteurs_score: scores.components.auteurs,
      box_office_score: scores.components.box_office,
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
        {:replace, ~w[mob_score critics_score festival_recognition_score time_machine_score
            auteurs_score box_office_score overall_score score_confidence
            disparity_score disparity_category unpredictability_score
            calculated_at calculation_version updated_at]a},
      conflict_target: :movie_id
    )
    |> case do
      {:ok, _} ->
        unless skip_cache_invalidation do
          Cinegraph.Movies.Cache.invalidate_search_results()
        end

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
    do_queue_all(0, batch_size)
    Cinegraph.Movies.Cache.invalidate_search_results()
  end

  defp do_queue_all(after_id, batch_size) do
    ids =
      from(m in Movie, where: m.id > ^after_id, order_by: m.id, limit: ^batch_size, select: m.id)
      |> Repo.all()

    unless ids == [] do
      jobs =
        Enum.map(ids, fn id -> new(%{"movie_id" => id, "skip_cache_invalidation" => true}) end)

      Oban.insert_all(jobs)
      do_queue_all(List.last(ids), batch_size)
    end
  end
end
