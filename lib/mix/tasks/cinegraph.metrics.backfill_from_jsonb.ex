defmodule Mix.Tasks.Cinegraph.Metrics.BackfillFromJsonb do
  use Mix.Task

  @shortdoc "Backfill external_metrics rows from existing tmdb_data/omdb_data JSONB (#913 Session 1)"

  @moduledoc """
  Closes the data-parity prerequisite from #913 by re-running
  `ExternalMetric.from_omdb/2` and `from_tmdb/2` against every movie whose
  JSONB column is populated, inserting any missing `external_metrics` rows.

  Idempotent: existing rows are skipped via the
  `(movie_id, source, metric_type)` unique index. Safe to run repeatedly.

  ## Usage

      mix cinegraph.metrics.backfill_from_jsonb --dry-run
      mix cinegraph.metrics.backfill_from_jsonb --source=omdb
      mix cinegraph.metrics.backfill_from_jsonb --source=tmdb --batch-size 100
      mix cinegraph.metrics.backfill_from_jsonb            # both

  ## Flags

  * `--source` — `omdb`, `tmdb`, or `all` (default: `all`)
  * `--dry-run` — run the parity queries and print the gap table without
    enqueuing any backfill. Exit 0 if all gaps are closed (`dest >= source`),
    exit 1 if any gap remains.
  * `--batch-size N` — movies per batch (default: 200). Smaller batches mean
    smaller in-flight memory; the throttle between batches is 500 ms.
  """

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Workers.DataRepairWorker

  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [source: :string, dry_run: :boolean, batch_size: :integer]
      )

    if invalid != [] do
      Mix.shell().error("Unknown options: #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
      Mix.raise("Invalid options provided")
    end

    source = parse_source(opts[:source] || "all")
    dry_run = opts[:dry_run] || false
    batch_size = opts[:batch_size] || 200

    Mix.Task.run("app.start")

    if dry_run do
      run_dry(source)
    else
      run_real(source, batch_size)
    end
  end

  # -- dry run ----------------------------------------------------------------

  defp run_dry(source) do
    results = parity_report(source)
    print_table(results)

    if Enum.all?(results, fn r -> r.gap == 0 end) do
      Mix.shell().info("\n✅ All in-scope metrics have dest >= source. No backfill needed.")
      :ok
    else
      Mix.shell().info("\n❌ Gaps detected. Run without --dry-run (or with --source=...) to backfill.")
      exit({:shutdown, 1})
    end
  end

  # -- real run ---------------------------------------------------------------

  defp run_real(source, batch_size) do
    Mix.shell().info("Pre-flight parity report:")
    parity_report(source) |> print_table()

    sources_to_run =
      case source do
        :all -> [:omdb, :tmdb]
        s -> [s]
      end

    Enum.each(sources_to_run, fn s ->
      Mix.shell().info("\nEnqueuing backfill_external_metrics_#{s} (batch_size=#{batch_size})…")

      case DataRepairWorker.start_external_metrics_backfill(s, batch_size: batch_size) do
        {:ok, %Oban.Job{id: id}} ->
          Mix.shell().info("  → Oban job #{id} inserted on :maintenance queue")

        {:error, reason} ->
          Mix.shell().error("  → failed to enqueue: #{inspect(reason)}")
      end
    end)

    Mix.shell().info("""

    Backfill is now running on the :maintenance queue. Watch progress with:

      docker exec cinegraph-web /app/bin/cinegraph rpc 'IO.inspect(Cinegraph.ObanQueueState.last_jobs("maintenance", limit: 5))'

    Or in the database:

      SELECT id, state, args->>'repair_type' AS type, meta FROM oban_jobs
        WHERE args->>'repair_type' LIKE 'backfill_external_metrics_%'
        ORDER BY id DESC LIMIT 5;

    Re-run this mix task with --dry-run when it finishes to confirm parity.
    """)

    :ok
  end

  # -- parity report ----------------------------------------------------------

  defp parity_report(source) do
    Enum.filter(parity_specs(), fn spec ->
      source == :all or source == spec.side
    end)
    |> Enum.map(fn spec ->
      src = Repo.one(spec.source_query)
      dst = Repo.one(spec.dest_query)
      %{label: spec.label, source: src, dest: dst, gap: max(src - dst, 0)}
    end)
  end

  defp parity_specs do
    [
      %{
        side: :omdb,
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
        side: :omdb,
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
        side: :omdb,
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
        side: :omdb,
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
        side: :omdb,
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
      },
      %{
        side: :tmdb,
        label: "TMDb revenue → tmdb/revenue_worldwide",
        source_query:
          from(m in "movies",
            where: fragment("(?->>'revenue')::bigint > 0", m.tmdb_data),
            select: count(m.id)
          ),
        dest_query:
          from(e in "external_metrics",
            where: e.source == "tmdb" and e.metric_type == "revenue_worldwide",
            select: count(e.id)
          )
      },
      %{
        side: :tmdb,
        label: "TMDb vote_average → tmdb/rating_average",
        source_query:
          from(m in "movies",
            where: fragment("(?->>'vote_average')::numeric > 0", m.tmdb_data),
            select: count(m.id)
          ),
        dest_query:
          from(e in "external_metrics",
            where: e.source == "tmdb" and e.metric_type == "rating_average",
            select: count(e.id)
          )
      }
    ]
  end

  # -- formatting -------------------------------------------------------------

  defp print_table(rows) do
    label_w = rows |> Enum.map(&String.length(&1.label)) |> Enum.max(fn -> 30 end)

    header =
      String.pad_trailing("Metric", label_w) <>
        "  " <>
        String.pad_leading("source", 10) <>
        "  " <>
        String.pad_leading("dest", 10) <>
        "  " <>
        String.pad_leading("gap", 10)

    Mix.shell().info(header)
    Mix.shell().info(String.duplicate("─", String.length(header)))

    Enum.each(rows, fn r ->
      Mix.shell().info(
        String.pad_trailing(r.label, label_w) <>
          "  " <>
          String.pad_leading(Integer.to_string(r.source), 10) <>
          "  " <>
          String.pad_leading(Integer.to_string(r.dest), 10) <>
          "  " <>
          String.pad_leading(if(r.gap > 0, do: "-#{r.gap}", else: "0"), 10)
      )
    end)
  end

  defp parse_source("omdb"), do: :omdb
  defp parse_source("tmdb"), do: :tmdb
  defp parse_source("all"), do: :all
  defp parse_source(other), do: Mix.raise("Unknown --source value: #{inspect(other)}")
end
