defmodule Cinegraph.Scoring.Lenses do
  @moduledoc "Single source of truth for the 6 scoring lens names and defaults."

  @lenses ~w(mob critics festival_recognition time_machine auteurs box_office)a

  # Lens configuration version (#1036). Bump when a lens's membership (which
  # metric_definitions.category feeds it), aggregation strategy, or weighting
  # changes. Trained prediction_models record the version they were fit against so
  # a lens change can flag them stale (Session 2).
  @lens_version "1"

  @default_weights %{
    "mob" => 0.10,
    "critics" => 0.10,
    "festival_recognition" => 0.20,
    "time_machine" => 0.20,
    "auteurs" => 0.20,
    "box_office" => 0.20
  }

  @default_atom_weights %{
    mob: 0.10,
    critics: 0.10,
    festival_recognition: 0.20,
    time_machine: 0.20,
    auteurs: 0.20,
    box_office: 0.20
  }

  @default_missing_data_strategies %{
    "mob" => "neutral",
    "critics" => "neutral",
    "festival_recognition" => "exclude",
    "time_machine" => "neutral",
    "auteurs" => "average",
    "box_office" => "exclude"
  }

  # :absolute aggregation strategy per lens (#1036 Layer 1).
  #   :weighted_mean — generic: the lens is the weight_within_lens-weighted mean of its
  #     catalog members, normalized to 0–10 via each member's raw_scale_max. Adding a
  #     catalog member to such a lens flows in with no code change.
  #   :custom — the lens has a bespoke formula in Cinegraph.Scoring.LensFormulas that
  #     reads specific named inputs (log/ROI/prestige/relational); the catalog drives
  #     which inputs load, the formula governs how they combine.
  @strategies %{
    mob: :weighted_mean,
    critics: :weighted_mean,
    festival_recognition: :custom,
    time_machine: :custom,
    auteurs: :custom,
    box_office: :custom
  }

  def all, do: @lenses
  def all_strings, do: Enum.map(@lenses, &to_string/1)
  def lens_version, do: @lens_version
  def strategies, do: @strategies
  def strategy(lens) when is_atom(lens), do: Map.fetch!(@strategies, lens)
  def weighted_mean_lenses, do: for({l, :weighted_mean} <- @strategies, do: l)
  def default_weights, do: @default_weights
  def default_atom_weights, do: @default_atom_weights
  def default_missing_data_strategies, do: @default_missing_data_strategies
end
