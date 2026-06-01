defmodule Mix.Tasks.Cinegraph.Refresh.Availability do
  @moduledoc """
  Enqueue a forced watch availability refresh for one or more movies by id.

  ## Usage

      mix cinegraph.refresh.availability 1187
      mix cinegraph.refresh.availability 1187 1188 1189
  """
  use Mix.Task

  alias CinegraphWeb.AdminHealth.Actions

  @shortdoc "Queue availability refresh for one or more movies by id"

  @doc false
  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    if args == [] do
      Mix.raise("Usage: mix cinegraph.refresh.availability <movie_id> [<movie_id>...]")
    end

    ids = Enum.map(args, &parse_id!/1)

    case Actions.queue_availability_refresh(ids) do
      {:ok, n} ->
        Mix.shell().info(
          "Enqueued #{n} MovieAvailabilityRefreshWorker job(s) on queue :movie_availability"
        )

      {:error, errors} ->
        Mix.shell().error("Enqueue failed: #{inspect(errors)}")
        exit({:shutdown, 1})

      {:partial, %{ok: n, errors: errors}} ->
        Mix.shell().error(
          "Partially enqueued #{n} MovieAvailabilityRefreshWorker job(s); failed batches: #{inspect(errors)}"
        )

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
