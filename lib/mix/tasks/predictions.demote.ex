defmodule Mix.Tasks.Predictions.Demote do
  @moduledoc """
  Demote / roll back a list's active prediction model (#1061 Session 2).

  Three modes:
    * **default (auto next-best)** — repoint at the best *other* sufficient promoted model for the
      list; if none qualifies, clear to "no prediction available".
    * `--clear` — force-clear the active model (nulls `trained_weights` too).
    * `--to MODEL_ID` — repoint at a specific prior model (must belong to the list; subject to the
      `:insufficient_reliability` activation guard).

  Dry-run by default; pass `--commit` to apply (it mutates the live serving pointer).

      mix predictions.demote --list cult_movies_400               # dry-run: auto next-best
      mix predictions.demote --list cult_movies_400 --commit       # apply auto next-best
      mix predictions.demote --list cult_movies_400 --clear --commit
      mix predictions.demote --list tspdt_1000 --to 14 --commit
  """
  use Mix.Task
  import Ecto.Query

  alias Cinegraph.Movies.MovieLists
  alias Cinegraph.Predictions.{Model, Reliability}
  alias Cinegraph.Repo

  @shortdoc "Roll a list's active model back to the next-best (or clear / --to); --commit to apply"

  @grade_rank %{high: 4, moderate: 3, low: 2, insufficient: 1}

  @impl Mix.Task
  def run(args) do
    Cinegraph.Predictions.TaskSupport.start_lean()

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [list: :string, to: :integer, clear: :boolean, commit: :boolean]
      )

    source_key = opts[:list] || Mix.raise("--list is required")

    target =
      cond do
        opts[:to] -> opts[:to]
        opts[:clear] -> :clear
        true -> :auto
      end

    if opts[:commit] do
      source_key |> demote(target) |> report(source_key)
    else
      Mix.shell().info("DRY-RUN — would #{describe(source_key, target)}. Re-run with --commit.")
    end
  end

  @doc """
  Demote core (#1061 Session 2), exposed for testing.

    * `:clear` — clear the active model (+ trained_weights cache).
    * `:auto` — repoint at the next-best *other* sufficient promoted model, else clear.
    * `id` (integer) — repoint at a specific prior model (guarded + same-list).

  Returns `{:ok, list}` or `{:error, reason}`.
  """
  def demote(source_key, target) do
    case MovieLists.get_by_source_key(source_key) do
      nil -> {:error, {:unknown_list, source_key}}
      list -> do_demote(source_key, list.active_prediction_model_id, target)
    end
  end

  defp do_demote(source_key, _current, :clear),
    do: MovieLists.set_active_prediction_model(source_key, nil, nil)

  defp do_demote(source_key, current, :auto) do
    case next_best(source_key, current) do
      nil -> MovieLists.set_active_prediction_model(source_key, nil, nil)
      model -> MovieLists.set_active_prediction_model(source_key, model.id, model.weights)
    end
  end

  defp do_demote(source_key, _current, id) when is_integer(id) do
    case Repo.get(Model, id) do
      nil ->
        {:error, {:model_not_found, id}}

      %Model{source_key: ^source_key} = m ->
        MovieLists.set_active_prediction_model(source_key, id, m.weights)

      %Model{source_key: other} ->
        {:error, {:wrong_list, id, other}}
    end
  end

  # Best OTHER promoted model for the list (excluding the current active), sufficient by Reliability,
  # ranked by grade then headline. nil if none qualify.
  defp next_best(source_key, current) do
    Repo.all(from m in Model, where: m.source_key == ^source_key)
    |> Enum.reject(&(&1.id == current))
    |> Enum.map(&{&1, Reliability.score(&1)})
    |> Enum.filter(fn {_m, s} -> s.grade != :insufficient end)
    |> Enum.sort_by(fn {_m, s} -> {@grade_rank[s.grade] || 0, s.headline_pct || 0.0} end, :desc)
    |> case do
      [{model, _} | _] -> model
      [] -> nil
    end
  end

  defp describe(source_key, :clear), do: "clear #{source_key}'s active model"

  defp describe(source_key, :auto) do
    list = MovieLists.get_by_source_key(source_key)

    case list && next_best(source_key, list.active_prediction_model_id) do
      nil -> "clear #{source_key} (no sufficient fallback model)"
      m -> "roll #{source_key} back to model ##{m.id} (#{m.model_class})"
    end
  end

  defp describe(source_key, id), do: "repoint #{source_key} at model ##{id}"

  defp report({:ok, _list}, source_key), do: Mix.shell().info("✓ #{source_key}: done")

  defp report({:error, {:insufficient_reliability, id}}, source_key),
    do:
      Mix.shell().error(
        "✗ #{source_key}: model ##{id} grades :insufficient — refused by the guard"
      )

  defp report({:error, reason}, source_key),
    do: Mix.shell().error("✗ #{source_key}: #{inspect(reason)}")
end
