defmodule Cinegraph.Metrics.OmdbParity do
  @moduledoc """
  Single source of truth for OMDb raw-blob → `external_metrics` parity (#1053).

  Each spec compares how many movies' `omdb_data` blob carries a given field
  (the **source** count) against how many `external_metrics` rows were derived
  from it (the **dest** count). A positive `gap` means we have stored OMDb
  responses whose metrics were never materialized — the materialization debt
  that `mix cinegraph.metrics.backfill_from_jsonb` closes (with no API calls).

  Consumers:
  - `Mix.Tasks.Cinegraph.Metrics.BackfillFromJsonb` — the `--dry-run` table.
  - `Cinegraph.Health.Drift.Ratings.omdb_materialization_parity/1` — watchdog.

  Specs cover all five OMDb-derived metric families. Note these write under
  four different `external_metrics` sources (`imdb`, `metacritic`, `omdb`,
  `rotten_tomatoes`) — which is exactly why "has a `source='omdb'` row" is the
  wrong terminal test for a movie (see `Cinegraph.ApiProcessors.OMDb`).
  """

  import Ecto.Query
  alias Cinegraph.Repo

  @doc """
  The five OMDb-derived parity specs, each `%{label, source_query, dest_query}`.
  `source_query`/`dest_query` are count queries to run with `Repo.one/1`.
  """
  def specs do
    [
      %{
        label: "OMDb imdbRating → imdb/rating_average",
        source_query:
          from(m in "movies",
            where:
              not is_nil(fragment("?->>'imdbRating'", m.omdb_data)) and
                fragment("?->>'imdbRating'", m.omdb_data) not in ["N/A", ""],
            select: count(m.id)
          ),
        dest_query:
          from(e in "external_metrics",
            where: e.source == "imdb" and e.metric_type == "rating_average",
            select: count(e.id)
          )
      },
      %{
        label: "OMDb Metascore → metacritic/metascore",
        source_query:
          from(m in "movies",
            where:
              not is_nil(fragment("?->>'Metascore'", m.omdb_data)) and
                fragment("?->>'Metascore'", m.omdb_data) not in ["N/A", ""],
            select: count(m.id)
          ),
        dest_query:
          from(e in "external_metrics",
            where: e.source == "metacritic" and e.metric_type == "metascore",
            select: count(e.id)
          )
      },
      %{
        label: "OMDb Awards → omdb/awards_summary",
        source_query:
          from(m in "movies",
            where:
              not is_nil(fragment("?->>'Awards'", m.omdb_data)) and
                fragment("?->>'Awards'", m.omdb_data) not in ["N/A", ""],
            select: count(m.id)
          ),
        dest_query:
          from(e in "external_metrics",
            where: e.source == "omdb" and e.metric_type == "awards_summary",
            select: count(e.id)
          )
      },
      %{
        label: "OMDb Rated → omdb/content_rating",
        source_query:
          from(m in "movies",
            where:
              not is_nil(fragment("?->>'Rated'", m.omdb_data)) and
                fragment("?->>'Rated'", m.omdb_data) not in [
                  "N/A",
                  "NOT RATED",
                  "UNRATED",
                  "NR",
                  ""
                ],
            select: count(m.id)
          ),
        dest_query:
          from(e in "external_metrics",
            where: e.source == "omdb" and e.metric_type == "content_rating",
            select: count(e.id)
          )
      },
      %{
        label: "OMDb Ratings[Rotten Tomatoes] → rotten_tomatoes/tomatometer",
        source_query:
          from(m in "movies",
            where:
              fragment("jsonb_typeof(?->'Ratings') = 'array'", m.omdb_data) and
                fragment(
                  "EXISTS (SELECT 1 FROM jsonb_array_elements(?->'Ratings') r WHERE r->>'Source' = 'Rotten Tomatoes')",
                  m.omdb_data
                ),
            select: count(m.id)
          ),
        dest_query:
          from(e in "external_metrics",
            where: e.source == "rotten_tomatoes" and e.metric_type == "tomatometer",
            select: count(e.id)
          )
      }
    ]
  end

  @doc """
  Run every spec and return `[%{label, source, dest, gap}]` where
  `gap = max(source - dest, 0)`. Pass a repo module (e.g. `Repo.replica()`) to
  route the reads; defaults to the primary `Repo`.
  """
  def gaps(repo \\ Repo) do
    Enum.map(specs(), fn spec ->
      src = repo.one(spec.source_query) || 0
      dst = repo.one(spec.dest_query) || 0
      %{label: spec.label, source: src, dest: dst, gap: max(src - dst, 0)}
    end)
  end
end
