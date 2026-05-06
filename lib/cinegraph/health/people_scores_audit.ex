defmodule Cinegraph.Health.PeopleScoresAudit do
  @moduledoc """
  Audits the auteurs score for a hardcoded set of ground-truth movies.

  Returns a structured map suitable for both the CLI (`mix cinegraph.audit_people_scores`)
  and the admin UI (`/admin/audits` via `Cinegraph.Admin.AuditRegistry`).

  Each row reports the calculated auteurs score, the minimum acceptable
  threshold for that title, and whether the score is below the threshold.
  """

  alias Cinegraph.Movies.{Movie, MovieScoring}
  alias Cinegraph.Repo

  # {tmdb_id, expected_title, min_acceptable_score (out of 10)}
  @ground_truth [
    {238, "The Godfather", 8.5},
    {424, "Schindler's List", 8.0},
    {62, "2001: A Space Odyssey", 7.5},
    {15_890, "Apocalypse Now", 7.5},
    {539, "Psycho", 7.5},
    {240, "The Godfather Part II", 8.0},
    {680, "Pulp Fiction", 8.0},
    {155, "The Dark Knight", 8.0},
    {490, "The Seventh Seal", 7.5},
    {372_058, "Your Name.", 7.0},
    {10_430, "Rashomon", 7.5},
    {129, "Spirited Away", 7.0},
    {843, "In the Mood for Love", 7.0},
    {11_517, "Persona", 7.5},
    {12_100, "La Dolce Vita", 7.5}
  ]

  @doc """
  Returns the canonical audit shape:

      %{
        generated_at: DateTime.t(),
        summary: %{
          total: integer(),
          missing: integer(),
          below_threshold: integer(),
          above_threshold: integer()
        },
        ground_truth: [
          %{
            tmdb_id: integer(),
            title: String.t(),
            min_score: float(),
            score: float() | nil,        # nil when movie is missing
            below_threshold: boolean(),
            top_people: [String.t()]
          },
          ...
        ]
      }
  """
  @spec audit(keyword()) :: map()
  def audit(_opts \\ []) do
    rows =
      Enum.map(@ground_truth, fn {tmdb_id, title, min_score} ->
        evaluate_row(tmdb_id, title, min_score)
      end)

    %{
      generated_at: DateTime.utc_now(),
      summary: summarize(rows),
      ground_truth: rows
    }
  end

  defp evaluate_row(tmdb_id, title, min_score) do
    case Repo.get_by(Movie, tmdb_id: tmdb_id) do
      nil ->
        %{
          tmdb_id: tmdb_id,
          title: title,
          min_score: min_score,
          score: nil,
          below_threshold: false,
          top_people: [],
          missing: true
        }

      movie ->
        info = MovieScoring.explain_auteurs_score(movie.id)
        score_10 = (info.avg_top10 || 0.0) / 10.0

        top_people =
          info.top_people
          |> Enum.take(3)
          |> Enum.map(fn {name, _job, _score, _weight} -> name end)

        %{
          tmdb_id: tmdb_id,
          title: title,
          min_score: min_score,
          score: Float.round(score_10 * 1.0, 2),
          below_threshold: score_10 < min_score,
          top_people: top_people,
          missing: false
        }
    end
  end

  defp summarize(rows) do
    total = length(rows)
    missing = Enum.count(rows, & &1.missing)
    below = Enum.count(rows, &(&1.below_threshold and not &1.missing))

    %{
      total: total,
      missing: missing,
      below_threshold: below,
      above_threshold: total - missing - below
    }
  end
end
