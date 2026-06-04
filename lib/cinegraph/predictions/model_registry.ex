defmodule Cinegraph.Predictions.ModelRegistry do
  @moduledoc """
  The registry of available prediction model classes (#1061 Session 1).

  Reads `Application.get_env(:cinegraph, :model_classes, [LinearLogReg])` so adding a class is a
  one-line config edit — no core changes. Each entry is a module implementing
  `Cinegraph.Predictions.ModelClass`. The first entry is the default (today: linear).

  Mirrors the single-source-of-truth pattern of `Cinegraph.Admin.JobRegistry`, but keyed on the
  model class's `key/0` rather than a hardcoded id.
  """

  require Logger

  alias Cinegraph.Predictions.LinearLogReg

  @doc "All registered model-class modules (config-backed; defaults to `[LinearLogReg]`)."
  # `|| [LinearLogReg]` (not just the get_env default) so an explicit `nil` config value also
  # falls back to linear rather than crashing `default/0`.
  def all, do: Application.get_env(:cinegraph, :model_classes) || [LinearLogReg]

  @doc "The default model class — the first registered (today: `LinearLogReg`)."
  def default, do: hd(all())

  @doc "The string keys of all registered classes."
  def keys, do: Enum.map(all(), & &1.key())

  @doc """
  Look up a class module by its `key/0`.
  Returns `{:ok, module}` or `{:error, {:unknown_model_class, key}}`.
  """
  def fetch(key) when is_binary(key) do
    case Enum.find(all(), &(&1.key() == key)) do
      nil -> {:error, {:unknown_model_class, key}}
      mod -> {:ok, mod}
    end
  end

  @doc """
  The training scope of a class (#1061 Session 2): `:per_cell` (fits one list at a time, the
  default) or `:pooled` (fits across all lists at once, then projects per target). Read from the
  optional `fit_scope/0` callback; classes that don't export it are `:per_cell`.
  """
  def fit_scope(key) when is_binary(key) do
    case fetch(key) do
      {:ok, mod} ->
        if function_exported?(mod, :fit_scope, 0), do: mod.fit_scope(), else: :per_cell

      {:error, _reason} ->
        # Surface typos/missing keys instead of silently defaulting (CodeRabbit #1064).
        Logger.warning(
          "ModelRegistry.fit_scope: unknown key #{inspect(key)}, defaulting :per_cell"
        )

        :per_cell
    end
  end

  @doc """
  Lifecycle status of a class (#1061 Session 2) — **config-only**, read from
  `:model_class_lifecycle` so it survives a class being dropped from `:model_classes` (a retired
  key still resolves). Defaults to `:experimental` for any key without an entry.

    * `:experimental` — runs in the matrix / ledger, but is NOT promotable.
    * `:active` — promotable (Session 2 further restricts *activation* to `linear_logreg`).
    * `:deprecated` — no new matrix runs, still served if currently active.
    * `:retired` — dropped from `:model_classes`; ledger rows persist.
  """
  def status(key) when is_binary(key) do
    Application.get_env(:cinegraph, :model_class_lifecycle, %{}) |> Map.get(key, :experimental)
  end

  @doc "Registered keys whose lifecycle status is `:active` — the only classes a promote may pick."
  def promotable_keys, do: Enum.filter(keys(), &(status(&1) == :active))
end
