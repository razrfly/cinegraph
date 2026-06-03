defmodule Cinegraph.Predictions.Model do
  @moduledoc """
  A trained/measured prediction model artifact (#1036, Layer 2) — the canonical store
  for machine-trained weights and their measurement, one row per
  `(source_key, weights_hash, model_version)`.

  Distinct from `metric_weight_profiles` (human-authored presets). `feature_set`
  declares the granularity (`"lens"` or `"data_point"`) and which features the model
  weights; `lens_config_hash` records the lens configuration it was trained against so
  a lens change can flag it `is_stale`. `metrics`/`calibration`/`integrity_report` are
  populated by the credibility engine (Session 3).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "prediction_models" do
    field :source_key, :string
    field :feature_set, :map, default: %{}
    field :weights, :map, default: %{}
    field :weights_hash, :string
    field :model_version, :integer, default: 1
    field :lens_config_hash, :string
    field :is_stale, :boolean, default: false
    field :backtest_strategy, :string
    field :metrics, :map, default: %{}
    field :calibration, :map, default: %{}
    field :integrity_report, :map, default: %{}
    field :holdout_spent_at, :utc_datetime

    belongs_to :pre_registration, Cinegraph.Predictions.PreRegistration, foreign_key: :prereg_id

    timestamps()
  end

  @doc false
  def changeset(model, attrs) do
    model
    |> cast(attrs, [
      :source_key,
      :feature_set,
      :weights,
      :weights_hash,
      :model_version,
      :lens_config_hash,
      :is_stale,
      :backtest_strategy,
      :metrics,
      :calibration,
      :integrity_report,
      :holdout_spent_at,
      :prereg_id
    ])
    |> validate_required([:source_key, :feature_set, :weights, :weights_hash, :model_version])
    |> unique_constraint([:source_key, :weights_hash, :model_version, :prereg_id],
      name: :prediction_models_artifact_uniq
    )
  end
end
