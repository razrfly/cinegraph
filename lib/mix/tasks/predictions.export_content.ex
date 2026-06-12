defmodule Mix.Tasks.Predictions.ExportContent do
  @moduledoc """
  Export the leakage-safe, content-only per-film record that a frontier model
  (Fable 5 / Opus 4.8) consumes for semantic feature extraction (#1113 Phase 0e).

  One JSONL row per film. The row carries ONLY the film's factual content —
  title, year, country, language, runtime, plot overview, genres, director, and
  the top-billed cast. It deliberately EXCLUDES everything that is the prediction
  target or circular with it: ratings/votes/awards (`external_metrics`), canon
  list membership (`canonical_sources`), and the raw `tmdb_data`/`omdb_data`
  blobs. The model must never see reception — it judges the work, not its status.

  ## Scope
    * `--scope pool` (default) — members of every canonical list + the global
      vote-gated candidate universe (`CandidateUniverse.global_ids/1`). The
      ~tens-of-thousands "pool tier" gated first per #1113 §3 before any
      full-catalog spend.
    * `--scope full` — every fully-imported feature with an overview (the later,
      ~catalog-scale tier).

  ## Usage
      mix predictions.export_content                         # pool tier → priv/dumps/
      mix predictions.export_content --scope full
      mix predictions.export_content --limit 100 --output /tmp/sample.jsonl
  """
  use Mix.Task
  import Ecto.Query

  alias Cinegraph.Movies.Movie
  alias Cinegraph.Predictions.CandidateUniverse
  alias Cinegraph.Repo

  @shortdoc "Export leakage-safe content-only per-film JSONL for LLM feature extraction (#1113)"

  @chunk 500
  @cast_keep 5

  @impl Mix.Task
  def run(args) do
    Cinegraph.Predictions.TaskSupport.start_lean()
    Logger.configure(level: :warning)

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [scope: :string, output: :string, limit: :integer]
      )

    scope = Keyword.get(opts, :scope, "pool")
    limit = Keyword.get(opts, :limit)
    output = Keyword.get(opts, :output) || default_output(scope)

    ids = scope |> scope_ids() |> maybe_limit(limit)
    File.mkdir_p!(Path.dirname(output))

    file = File.open!(output, [:write, :utf8])

    {written, no_overview} =
      ids
      |> Enum.chunk_every(@chunk)
      |> Enum.reduce({0, 0}, fn chunk, {w, n} ->
        rows = load_rows(chunk)
        Enum.each(rows, fn row -> IO.write(file, [Jason.encode!(row), "\n"]) end)
        empties = Enum.count(rows, &(&1.overview in [nil, ""]))
        {w + length(rows), n + empties}
      end)

    File.close(file)

    Mix.shell().info("""
    content export — #{scope} tier
    #{String.duplicate("=", 48)}
    films written : #{written}
    blank overview: #{no_overview} (model gets thin input → low confidence)
    output        : #{output}
    NOTE: leakage-safe — no ratings/awards/list-membership in any row.
    """)
  end

  # ── scope ────────────────────────────────────────────────────────────────────
  defp scope_ids("pool") do
    {members, negs} = CandidateUniverse.global_ids()
    (members ++ negs) |> Enum.uniq()
  end

  defp scope_ids("full") do
    Repo.all(
      from m in "movies",
        where: m.import_status == "full" and not is_nil(m.overview),
        select: m.id
    )
  end

  defp scope_ids(other) do
    Mix.raise("unknown --scope #{inspect(other)} (expected: pool | full)")
  end

  defp maybe_limit(ids, nil), do: ids
  defp maybe_limit(ids, n) when is_integer(n), do: Enum.take(ids, n)

  # ── row building ───────────────────────────────────────────────────────────────
  # Load a chunk via the Movie schema. `tmdb_data`/`omdb_data` are load_in_query:false
  # so they are never shipped; preloads cover only content associations (no external_metrics).
  defp load_rows(ids) do
    Repo.all(
      from m in Movie,
        where: m.id in ^ids,
        preload: [:genres, :production_countries, :spoken_languages, movie_credits: :person]
    )
    |> Enum.map(&to_row/1)
  end

  defp to_row(m) do
    %{
      movie_id: m.id,
      tmdb_id: m.tmdb_id,
      title: m.title || m.original_title,
      original_title: m.original_title,
      release_year: Movie.release_year(m),
      runtime: m.runtime,
      country: countries(m),
      original_language: m.original_language,
      spoken_languages: Enum.map(m.spoken_languages, & &1.english_name),
      genres: Enum.map(m.genres, & &1.name),
      director: directors(m),
      cast: top_cast(m),
      overview: m.overview
    }
  end

  defp countries(m) do
    case Enum.map(m.production_countries, & &1.name) do
      [] -> m.origin_country || []
      names -> names
    end
  end

  defp directors(m) do
    m.movie_credits
    |> Enum.filter(&(&1.credit_type == "crew" and &1.job in ["Director", "Co-Director"]))
    |> Enum.map(&person_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp top_cast(m) do
    m.movie_credits
    |> Enum.filter(&(&1.credit_type == "cast"))
    |> Enum.sort_by(&(&1.cast_order || 9999))
    |> Enum.take(@cast_keep)
    |> Enum.map(&person_name/1)
    |> Enum.reject(&is_nil/1)
  end

  defp person_name(%{person: %{name: name}}), do: name
  defp person_name(_), do: nil

  defp default_output("full"), do: "priv/dumps/content_export_full.jsonl"
  defp default_output(_), do: "priv/dumps/content_export_pool.jsonl"
end
