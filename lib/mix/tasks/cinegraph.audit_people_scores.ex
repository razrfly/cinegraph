defmodule Mix.Tasks.Cinegraph.AuditPeopleScores do
  @moduledoc """
  Audits auteurs scores for a hardcoded set of ground-truth movies.

  Usage:
    mix cinegraph.audit_people_scores

  Prints a table with the auteurs score for each movie and flags
  any known-high film that scores below 7.0.
  """
  use Mix.Task

  @shortdoc "Audit auteurs scores for ground-truth movies"

  # {tmdb_id, expected_title, min_acceptable_score}
  @ground_truth [
    {238, "The Godfather", 8.5},
    {424, "Schindler's List", 8.0},
    {62, "2001: A Space Odyssey", 7.5},
    {15890, "Apocalypse Now", 7.5},
    {539, "Psycho", 7.5},
    {240, "The Godfather Part II", 8.0},
    {680, "Pulp Fiction", 8.0},
    {155, "The Dark Knight", 8.0},
    {490, "The Seventh Seal", 7.5},
    {372_058, "Your Name.", 7.0},
    {10430, "Rashomon", 7.5},
    {129, "Spirited Away", 7.0},
    {843, "In the Mood for Love", 7.0},
    {11517, "Persona", 7.5},
    {12100, "La Dolce Vita", 7.5}
  ]

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    alias Cinegraph.Repo
    alias Cinegraph.Movies.MovieScoring
    alias Cinegraph.Movies.Movie

    IO.puts("\nAuteurs Score Audit")
    IO.puts(String.duplicate("─", 80))

    IO.puts(
      String.pad_trailing("Movie", 35) <>
        String.pad_leading("auteurs_score", 13) <>
        String.pad_leading("min", 8) <>
        "  top cast"
    )

    IO.puts(String.duplicate("─", 80))

    for {tmdb_id, title, min_score} <- @ground_truth do
      case Repo.get_by(Movie, tmdb_id: tmdb_id) do
        nil ->
          IO.puts("  #{title} (tmdb:#{tmdb_id}) — NOT IN DATABASE")

        movie ->
          info = MovieScoring.explain_auteurs_score(movie.id)
          score_10 = info.avg_top10 / 10.0

          top_names =
            info.top_people
            |> Enum.take(3)
            |> Enum.map(fn {name, _job, _score, _weight} -> name end)
            |> Enum.join(", ")

          flag = if score_10 < min_score, do: " ⚠️ ", else: "   "

          IO.puts(
            flag <>
              String.pad_trailing(title, 33) <>
              String.pad_leading(format_score(score_10), 8) <>
              String.pad_leading("≥#{min_score}", 8) <>
              "  #{top_names}"
          )
      end
    end

    IO.puts(String.duplicate("─", 80))
    IO.puts("Done.\n")
  end

  defp format_score(s), do: :erlang.float_to_binary(s * 1.0, decimals: 2)
end
