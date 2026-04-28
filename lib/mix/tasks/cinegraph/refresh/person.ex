defmodule Mix.Tasks.Cinegraph.Refresh.Person do
  @moduledoc """
  Enqueue a TMDb refresh for one or more people by id (#745 Phase 3.1).
  CLI counterpart of the `/admin/health` People drawer's "Queue TMDb refresh"
  button — both call `CinegraphWeb.AdminHealth.Actions.queue_person_tmdb_refresh/1`.

  ## Usage

      mix cinegraph.refresh.person 3
      mix cinegraph.refresh.person 3 8 11
  """
  use Mix.Task

  @shortdoc "Queue TMDb refresh for one or more people by id"

  alias CinegraphWeb.AdminHealth.Actions

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    if args == [] do
      Mix.raise("Usage: mix cinegraph.refresh.person <person_id> [<person_id>...]")
    end

    ids = Enum.map(args, &parse_id!/1)

    case Actions.queue_person_tmdb_refresh(ids) do
      {:ok, n} ->
        Mix.shell().info("Enqueued #{n} PersonTmdbRefreshWorker job(s) on queue :tmdb")

      {:error, errors} ->
        Mix.shell().error("Enqueue failed: #{inspect(errors)}")
        exit({:shutdown, 1})
    end
  end

  defp parse_id!(arg) do
    case Integer.parse(arg) do
      {n, ""} when n > 0 -> n
      _ -> Mix.raise("Invalid person id: #{inspect(arg)} (must be a positive integer)")
    end
  end
end
