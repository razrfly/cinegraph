# One-time trigger: immediately queue all 1001-list films missing OMDb data.
#
# Usage: mix run priv/scripts/queue_1001_omdb_backfill.exs
#
# Bypasses the 3 AM RatingsRefreshWorker cron. Safe to run multiple times —
# Oban deduplicates jobs already in the queue.

import Ecto.Query
alias Cinegraph.Repo
alias Cinegraph.Movies.Movie
alias Cinegraph.Movies.ExternalMetric
alias Cinegraph.Workers.OMDbEnrichmentWorker

cooldown_cutoff = DateTime.add(DateTime.utc_now(), -90 * 24 * 3600, :second)

recently_checked =
  from(em in ExternalMetric,
    where: em.source == "omdb" and em.metric_type == "fetch_attempt",
    where: em.fetched_at > ^cooldown_cutoff,
    select: em.movie_id
  )

ids =
  from(m in Movie,
    where: m.import_status == "full",
    where: is_nil(m.omdb_data),
    where: not is_nil(m.imdb_id),
    where: fragment("? \\? '1001_movies'", m.canonical_sources),
    where: m.id not in subquery(recently_checked),
    select: m.id
  )
  |> Repo.all()

IO.puts("Queuing #{length(ids)} 1001-list films for OMDb enrichment...")

{queued, failed} =
  Enum.reduce(ids, {0, 0}, fn id, {ok, err} ->
    case Oban.insert(OMDbEnrichmentWorker.new(%{"movie_id" => id})) do
      {:ok, _} -> {ok + 1, err}
      {:error, _} -> {ok, err + 1}
    end
  end)

IO.puts("Done — queued: #{queued}, failed: #{failed}")
