defmodule Cinegraph.Repo.Migrations.CreatePredictionModels do
  use Ecto.Migration

  # #1036 Session 2 (Layer 2): the canonical store for TRAINED/MEASURED models — one row
  # per (source_key, weights_hash, model_version) candidate. Human presets stay in
  # metric_weight_profiles; this holds machine-trained weights + their measurement.
  def change do
    create table(:prediction_models) do
      add :source_key, :string, null: false
      # %{"granularity" => "lens"|"data_point", "features" => [...]} — the decoupler
      add :feature_set, :map, null: false, default: %{}
      add :weights, :map, null: false, default: %{}
      # hash over (granularity, ordered features, weights, model_version, lens_config_hash)
      add :weights_hash, :string, null: false
      add :model_version, :integer, null: false, default: 1
      # fingerprint of the active lens config trained against; null for :data_point models
      add :lens_config_hash, :string
      add :is_stale, :boolean, null: false, default: false
      add :backtest_strategy, :string
      add :metrics, :map, default: %{}
      add :calibration, :map, default: %{}
      add :integrity_report, :map, default: %{}
      add :holdout_spent_at, :utc_datetime
      add :prereg_id, references(:prediction_pre_registrations, on_delete: :nilify_all)
      timestamps()
    end

    create unique_index(:prediction_models, [:source_key, :weights_hash, :model_version])
    create index(:prediction_models, [:source_key, :is_stale])
  end
end
