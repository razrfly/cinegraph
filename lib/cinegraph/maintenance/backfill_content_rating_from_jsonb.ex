defmodule Cinegraph.Maintenance.BackfillContentRatingFromJsonb do
  @moduledoc """
  Re-extracts OMDb content_rating metrics from existing `omdb_data` JSONB
  without making any API calls.

  Targets movies where `omdb_data` is populated and contains a valid `Rated`
  field, but no `external_metrics` row for `(source='omdb',
  metric_type='content_rating')` exists yet. This covers movies fetched before
  the content_rating extraction was added, or where an earlier metrics pipeline
  run skipped it.

  Reachable from:
  - `mix cinegraph.movies.backfill_content_rating_from_jsonb` (dev)
  - `bin/cinegraph eval "Cinegraph.Maintenance.BackfillContentRatingFromJsonb.run([])"` (one-shot prod)

  Canonical-list movies are prioritised first, then by `id DESC`.

  See #989 Action 1.

  ## Options
    * `:dry_run` (boolean) — count only; do not process.
    * `:batch_size` (positive integer) — rows loaded per DB round-trip (default 500).

  ## Returns
  `{:ok, %{found: integer, processed: integer, failed: integer, dry_run: boolean}}`
  """

  alias Cinegraph.{Repo, Metrics}
  alias Cinegraph.Movies.Movie

  import Ecto.Query
  require Logger

  @default_batch_size 500
  @excluded_ratings ["N/A", "NOT RATED", "UNRATED", "NR", ""]

  @spec run(keyword()) ::
          {:ok,
           %{
             found: non_neg_integer(),
             processed: non_neg_integer(),
             failed: non_neg_integer(),
             dry_run: boolean()
           }}
  def run(opts \\ []) when is_list(opts) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    ids_query =
      from m in "movies",
        where:
          fragment(
            "? IS NOT NULL AND ? != '{}'::jsonb AND ?->>'Rated' IS NOT NULL AND UPPER(TRIM(?->>'Rated')) != ALL(?)",
            m.omdb_data,
            m.omdb_data,
            m.omdb_data,
            m.omdb_data,
            ^@excluded_ratings
          ),
        where:
          not fragment(
            "EXISTS (SELECT 1 FROM external_metrics em WHERE em.movie_id = ? AND em.source = 'omdb' AND em.metric_type = 'content_rating')",
            m.id
          ),
        order_by: [
          desc: fragment("? != '{}'::jsonb", m.canonical_sources),
          desc: m.id
        ],
        select: m.id

    ids = Repo.replica().all(ids_query)
    found = length(ids)

    Logger.info("BackfillContentRatingFromJsonb: found=#{found} movies to process")

    if dry_run? do
      {:ok, %{found: found, processed: 0, failed: 0, dry_run: true}}
    else
      {processed, failed} = process_in_batches(ids, batch_size)

      Logger.info("BackfillContentRatingFromJsonb: processed=#{processed} failed=#{failed}")

      {:ok, %{found: found, processed: processed, failed: failed, dry_run: false}}
    end
  end

  defp process_in_batches(ids, batch_size) do
    ids
    |> Enum.chunk_every(batch_size)
    |> Enum.reduce({0, 0}, fn chunk, {ok, err} ->
      movies =
        Repo.all(
          from m in Movie,
            where: m.id in ^chunk,
            select_merge: %{omdb_data: m.omdb_data}
        )

      Enum.reduce(movies, {ok, err}, fn movie, {o, e} ->
        result =
          try do
            Metrics.store_omdb_metrics(movie, movie.omdb_data)
          rescue
            e -> {:error, e}
          end

        case result do
          :ok ->
            {o + 1, e}

          {:error, reason} ->
            Logger.error(
              "BackfillContentRatingFromJsonb: movie_id=#{movie.id} #{inspect(reason)}"
            )

            {o, e + 1}
        end
      end)
    end)
  end
end
