defmodule Mix.Tasks.Cinegraph.Refresh.Omdb do
  @moduledoc """
  Enqueue an OMDb refresh for one or more movies by id (#745 Phase 3.1).
  CLI counterpart of the `/admin/health` Ratings drawer's "Queue OMDb refresh"
  button — both call `CinegraphWeb.AdminHealth.Actions.queue_omdb_refresh/1`.

  Different shape from `mix cinegraph.movies.backfill_omdb` (which is a
  catalog-wide sweeper). This task is for ad-hoc per-movie refreshes —
  `--force` is implied (always re-fetches even if `omdb_data` is set).

  ## Usage

      mix cinegraph.refresh.omdb 1187
      mix cinegraph.refresh.omdb 1187 1188 1189
  """
  use Mix.Task

  @shortdoc "Queue OMDb refresh for one or more movies by id"

  alias CinegraphWeb.AdminHealth.Actions

  @doc false
  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    if args == [] do
      Mix.raise("Usage: mix cinegraph.refresh.omdb <movie_id> [<movie_id>...]")
    end

    ids = Enum.map(args, &parse_id!/1)

    case Actions.queue_omdb_refresh(ids) do
      {:ok, n} ->
        Mix.shell().info("Enqueued #{n} OMDbEnrichmentWorker job(s) on queue :omdb")

      {:partial, %{ok: n, errors: errors}} ->
        Mix.shell().error(
          "Partially enqueued #{n} OMDbEnrichmentWorker job(s); failed ids: #{inspect(errors)}"
        )

        exit({:shutdown, 1})

      {:error, errors} ->
        Mix.shell().error("Enqueue failed: #{inspect(errors)}")
        exit({:shutdown, 1})
    end
  end

  defp parse_id!(arg) do
    case Integer.parse(arg) do
      {n, ""} when n > 0 -> n
      _ -> Mix.raise("Invalid movie id: #{inspect(arg)} (must be a positive integer)")
    end
  end
end
