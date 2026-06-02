defmodule Mix.Tasks.Cinegraph.Scoring.Rewarm do
  @moduledoc """
  Re-warm `movie_score_caches` for all fully-imported movies, in parallel.

  Runs each movie through `MovieScoreCacheWorker.perform/1` (compute + upsert) via
  `Task.async_stream`, so throughput scales with `--concurrency`. Use a high value on
  a big local box, a smaller one in production so the app's DB pool isn't starved.

      mix cinegraph.scoring.rewarm                      # concurrency = CPU cores
      mix cinegraph.scoring.rewarm --concurrency 16     # local, fast
      mix cinegraph.scoring.rewarm --concurrency 6      # production-safe
      mix cinegraph.scoring.rewarm --from 500000        # resume from a movie id

  Concurrency is capped so it can't exceed the repo pool minus a small headroom.
  In production this is also runnable via `kamal console` / `Cinegraph.ProdRpc`.
  """
  use Mix.Task
  import Ecto.Query

  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Workers.MovieScoreCacheWorker

  @shortdoc "Parallel re-warm of movie_score_caches (concurrency-tunable)"
  @page 2000

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args, strict: [concurrency: :integer, limit: :integer, from: :integer])

    pool = Application.get_env(:cinegraph, Repo)[:pool_size] || 25
    requested = opts[:concurrency] || System.schedulers_online()
    concurrency = max(1, min(requested, pool - 4))
    limit = opts[:limit]
    started = System.monotonic_time(:millisecond)

    IO.puts(
      "Re-warming with concurrency=#{concurrency} (requested #{requested}, pool #{pool})" <>
        "#{if limit, do: ", limit #{limit}", else: ""}…"
    )

    total = stream_pages(opts[:from] || 0, limit, concurrency, 0)

    secs = (System.monotonic_time(:millisecond) - started) / 1000
    rate = if secs > 0, do: Float.round(total / secs, 0), else: 0
    IO.puts("\nDONE re-warmed #{total} movies in #{Float.round(secs, 1)}s (#{rate}/s)")

    # A re-warm follows a lens/calc change — propagate staleness to dependent :lens models
    # (idempotent: only flips models whose lens_config_hash no longer matches; data-point untouched).
    case Cinegraph.Predictions.mark_stale_lens_models() do
      0 -> :ok
      n -> IO.puts("Flagged #{n} :lens prediction_model(s) stale (lens configuration changed).")
    end
  end

  defp stream_pages(after_id, limit, concurrency, done) do
    page_size = if limit, do: min(@page, limit - done), else: @page

    ids =
      from(m in Movie,
        where: m.import_status == "full" and m.id > ^after_id,
        order_by: m.id,
        limit: ^page_size,
        select: m.id
      )
      |> Repo.all()

    if ids == [] do
      done
    else
      # Direct synchronous perform/1 (NOT Oban enqueue) is intentional: a fast parallel
      # one-shot rewarm, not the retried Oban drip. But surface failures — don't count a
      # movie as done if its compute/upsert errored or the task crashed/timed out.
      failures =
        ids
        |> Task.async_stream(
          fn id ->
            MovieScoreCacheWorker.perform(%Oban.Job{
              args: %{"movie_id" => id, "skip_cache_invalidation" => true}
            })
          end,
          max_concurrency: concurrency,
          timeout: :timer.seconds(60),
          ordered: false
        )
        |> Enum.reduce([], fn
          {:ok, :ok}, acc -> acc
          {:ok, {:error, reason}}, acc -> [reason | acc]
          {:exit, reason}, acc -> [reason | acc]
        end)

      if failures != [] do
        Mix.raise(
          "Rewarm failed for #{length(failures)} movie(s): #{inspect(Enum.take(failures, 5))}"
        )
      end

      done = done + length(ids)
      if rem(done, 20_000) < page_size, do: IO.write("[#{done}]")

      if limit && done >= limit,
        do: done,
        else: stream_pages(List.last(ids), limit, concurrency, done)
    end
  end
end
