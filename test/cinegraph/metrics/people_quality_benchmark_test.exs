defmodule Cinegraph.Metrics.PeopleQualityBenchmarkTest do
  @moduledoc """
  Ground-truth benchmark tests for people_quality scoring.

  These tests require real data in the database and will fail if a ground-truth
  movie is absent. They serve as regression guards after scoring changes.
  """
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Repo
  alias Cinegraph.Movies.{Movie, MovieScoring}

  @ground_truth [
    {238, "The Godfather", 8.5},
    {424, "Schindler's List", 8.0},
    {62, "2001: A Space Odyssey", 7.5}
  ]

  for {tmdb_id, title, min_score} <- @ground_truth do
    test "#{title} people_quality >= #{min_score}" do
      tmdb_id = unquote(tmdb_id)
      title = unquote(title)
      min_score = unquote(min_score)

      movie = Repo.get_by(Movie, tmdb_id: tmdb_id)

      if is_nil(movie) do
        flunk("#{title} (tmdb_id=#{tmdb_id}) not in database — add it to run benchmarks")
      else
        scores = MovieScoring.calculate_movie_scores(movie)
        people_quality = scores.components.people_quality

        assert people_quality >= min_score,
               "Expected #{title} people_quality >= #{min_score}, got #{people_quality}"
      end
    end
  end
end
