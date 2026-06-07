defmodule Cinegraph.Scoring.MetricSource do
  @moduledoc """
  Which relation the hot feature-load paths read (#1082 / #1084 P1).

  `metric_values_view` (the live logical view) and `metric_values_matview` (its
  materialization, refreshed daily + on demand) are column-identical and — by the
  view's outer GROUP BY — row-identical at refresh time. The knob exists for one
  reason: **the test suite must read the live view** (sandboxed fixtures are
  invisible to a matview), while dev/prod read the matview so feature loading is
  an index scan instead of a 7-branch UNION re-derivation (~11.5ms/movie on prod).

      config :cinegraph, :metric_values_relation, "metric_values_matview"

  Consumers: `DataPointFeatures.load/2` and `DerivedFeatures.presence_sets/2` —
  the two queries behind every train/serve feature vector. Cold paths (admin
  LiveViews, dev audit tasks) deliberately stay on the live view.
  """

  require Logger

  alias Cinegraph.Repo

  @allowed ~w(metric_values_view metric_values_matview)
  @view "metric_values_view"
  @matview "metric_values_matview"

  @doc """
  The relation name for hot feature reads. Allowlisted — safe to interpolate into SQL.

  Bootstrap safety: the matview ships `WITH NO DATA`, so between deploy and its first
  refresh a configured `metric_values_matview` would serve ZERO features — silently wrong
  rankings, cached for hours. Until `pg_matviews.ispopulated` flips true we fall back to
  the live view (slow but correct); the answer then latches in `:persistent_term` so the
  steady-state cost is one ETS read.
  """
  def relation do
    configured = Application.get_env(:cinegraph, :metric_values_relation, @view)

    if configured in @allowed do
      resolve(configured)
    else
      raise ArgumentError,
            ":metric_values_relation must be one of #{inspect(@allowed)}, got: #{inspect(configured)}"
    end
  end

  defp resolve(@matview) do
    if matview_ready?(), do: @matview, else: @view
  end

  defp resolve(view), do: view

  # One-way latch: re-checks the catalog until the first populate, then never queries again.
  defp matview_ready? do
    :persistent_term.get({__MODULE__, :populated}, false) ||
      case Repo.query(
             "SELECT ispopulated FROM pg_matviews WHERE schemaname = 'public' AND matviewname = $1",
             [@matview]
           ) do
        {:ok, %{rows: [[true]]}} ->
          :persistent_term.put({__MODULE__, :populated}, true)
          true

        _ ->
          warn_unpopulated_once()
          false
      end
  end

  defp warn_unpopulated_once do
    unless :persistent_term.get({__MODULE__, :warned}, false) do
      :persistent_term.put({__MODULE__, :warned}, true)

      Logger.warning(
        "MetricSource: #{@matview} is configured but unpopulated (or absent) — " <>
          "falling back to #{@view} until its first REFRESH"
      )
    end
  end

  @doc false
  # Test hook: clear the persistent_term latches.
  def reset_latch do
    :persistent_term.erase({__MODULE__, :populated})
    :persistent_term.erase({__MODULE__, :warned})
    :ok
  end
end
