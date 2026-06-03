defmodule Cinegraph.Predictions.ModelRegistry do
  @moduledoc """
  The registry of available prediction model classes (#1061 Session 1).

  Reads `Application.get_env(:cinegraph, :model_classes, [LinearLogReg])` so adding a class is a
  one-line config edit — no core changes. Each entry is a module implementing
  `Cinegraph.Predictions.ModelClass`. The first entry is the default (today: linear).

  Mirrors the single-source-of-truth pattern of `Cinegraph.Admin.JobRegistry`, but keyed on the
  model class's `key/0` rather than a hardcoded id.
  """

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
end
