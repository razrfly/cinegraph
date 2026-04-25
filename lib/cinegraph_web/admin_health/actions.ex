defmodule CinegraphWeb.AdminHealth.Actions do
  @moduledoc """
  Dashboard-specific write actions for the `/admin/health` drawers (#723).

  Deliberately kept **outside** the `Cinegraph.Health.*` namespace, which is
  read-only by design. Wraps existing Oban workers in a uniform CLI-friendly
  interface so the LiveView's `handle_event/3` can call into one place.

  Returns `{:ok, n_queued}` on success or `{:error, reason}`.
  """

  alias Cinegraph.Workers.{OMDbEnrichmentWorker, PersonTmdbRefreshWorker}

  require Logger

  @doc """
  Enqueue an OMDb refresh for each given movie id. Backed by
  `Cinegraph.Workers.OMDbEnrichmentWorker`.

      Actions.queue_omdb_refresh([1, 2, 3])
      #=> {:ok, 3}

      Actions.queue_omdb_refresh([])
      #=> {:ok, 0}
  """
  @spec queue_omdb_refresh([integer()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def queue_omdb_refresh(movie_ids) when is_list(movie_ids) do
    enqueue(movie_ids, fn id ->
      OMDbEnrichmentWorker.new(%{"movie_id" => id, "force" => true})
    end)
  end

  @doc """
  Enqueue a TMDb refresh for each given person id. Backed by
  `Cinegraph.Workers.PersonTmdbRefreshWorker`.
  """
  @spec queue_person_tmdb_refresh([integer()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def queue_person_tmdb_refresh(person_ids) when is_list(person_ids) do
    enqueue(person_ids, fn id ->
      PersonTmdbRefreshWorker.new(%{"person_id" => id})
    end)
  end

  defp enqueue([], _builder), do: {:ok, 0}

  defp enqueue(ids, builder) do
    {ok_count, errors} =
      Enum.reduce(ids, {0, []}, fn id, {n, errs} ->
        case id |> builder.() |> Oban.insert() do
          {:ok, _job} ->
            {n + 1, errs}

          # An existing matching job already exists — count it as queued.
          {:error, %Ecto.Changeset{errors: [args: {"has already been taken", _}]}} ->
            {n + 1, errs}

          {:error, reason} ->
            {n, [{id, reason} | errs]}
        end
      end)

    case errors do
      [] ->
        {:ok, ok_count}

      _ ->
        Logger.warning(
          "AdminHealth.Actions enqueue partial failure: #{ok_count} ok, #{length(errors)} errors"
        )

        {:ok, ok_count}
    end
  end
end
