defmodule Mix.Tasks.Predictions.BackfillUniverse do
  @moduledoc """
  Densify the prediction **candidate universe** with OMDb data (#1051 Stage A2).

  Scopes `Cinegraph.Maintenance.BackfillOmdb` to the global candidate universe (members of any
  canonical list ∪ vote-gated non-members, members first) and fetches OMDb for the movies in
  that set that have no OMDb row yet. OMDb returns Metacritic + Rotten Tomatoes + IMDb in one
  call, so this is the highest-ROI densifier for the under-covered critic features.

  Genuine misses are recorded as `external_metrics` `fetch_attempt` rows (source-absent, 90-day
  cooldown) by the worker — so re-runs skip them and the coverage audit can tell source-absent
  from not-yet-fetched.

  ## Usage

      mix predictions.backfill_universe --dry-run     # count the backlog only
      mix predictions.backfill_universe               # fetch synchronously (members first)
      mix predictions.backfill_universe --limit 100   # cap the run
      mix predictions.backfill_universe --enqueue     # enqueue to the :omdb Oban queue instead

  ## Options
    * `--dry-run` — report how many universe movies lack OMDb; fetch nothing.
    * `--limit N` — cap the number processed.
    * `--enqueue` — use the Oban queue (production path) instead of synchronous fetching.
    * `--min-votes N` — vote gate for non-member candidates (default 1000).
  """
  use Mix.Task

  alias Cinegraph.Maintenance.BackfillOmdb
  alias Cinegraph.Predictions.CandidateUniverse
  alias Cinegraph.Workers.OMDbEnrichmentWorker

  @shortdoc "Densify the prediction candidate universe via OMDb (#1051 Stage A2)"

  # Politeness pause between synchronous OMDb calls (the Oban omdb queue spaces ~250ms at
  # concurrency 5; this single-threaded loop uses a similar gap).
  @sleep_ms 200

  @impl Mix.Task
  def run(args) do
    Cinegraph.Predictions.TaskSupport.start_lean()

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [dry_run: :boolean, limit: :integer, enqueue: :boolean, min_votes: :integer]
      )

    min_votes = Keyword.get(opts, :min_votes, 1000)
    limit = Keyword.get(opts, :limit)

    {members, negs} = CandidateUniverse.global_ids(min_votes: min_votes)
    universe = members ++ negs
    base_opts = [movie_ids: universe] ++ if(limit, do: [limit: limit], else: [])

    ids = BackfillOmdb.eligible_ids(base_opts)

    Mix.shell().info(
      "Candidate universe: #{length(universe)} movies (#{length(members)} members, #{length(negs)} non-members). " <>
        "Missing OMDb: #{length(ids)}#{if limit, do: " (capped to #{limit})", else: ""}."
    )

    cond do
      Keyword.get(opts, :dry_run, false) ->
        Mix.shell().info("Dry run — nothing fetched.")

      Keyword.get(opts, :enqueue, false) ->
        {:ok, stats} = BackfillOmdb.run(base_opts)

        Mix.shell().info(
          "Enqueued #{stats.enqueued} OMDb jobs on :omdb (#{stats.failed} failed)."
        )

      true ->
        run_sync(ids)
    end
  end

  defp run_sync([]),
    do: Mix.shell().info("Nothing to fetch — universe already has OMDb coverage.")

  defp run_sync(ids) do
    total = length(ids)
    Mix.shell().info("Fetching OMDb for #{total} movies synchronously (members first)...")

    {ok, err} =
      ids
      |> Enum.with_index(1)
      |> Enum.reduce({0, 0}, fn {id, i}, {ok, err} ->
        result =
          try do
            OMDbEnrichmentWorker.perform(%Oban.Job{args: %{"movie_id" => id}})
          rescue
            e -> {:error, Exception.message(e)}
          end

        acc =
          case result do
            :ok -> {ok + 1, err}
            {:ok, _} -> {ok + 1, err}
            _ -> {ok, err + 1}
          end

        if rem(i, 25) == 0 or i == total do
          Mix.shell().info(
            "  #{i}/#{total} processed (ok=#{elem(acc, 0)} miss/err=#{elem(acc, 1)})"
          )
        end

        Process.sleep(@sleep_ms)
        acc
      end)

    Mix.shell().info(
      "Done. Stored=#{ok}, missing-or-failed=#{err} (the latter recorded as fetch_attempt)."
    )
  end
end
