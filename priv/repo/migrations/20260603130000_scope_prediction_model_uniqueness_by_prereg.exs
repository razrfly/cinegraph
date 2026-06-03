defmodule Cinegraph.Repo.Migrations.ScopePredictionModelUniquenessByPrereg do
  use Ecto.Migration

  # #1042: include prereg_id in the uniqueness key so two DISTINCT pre-registrations that
  # converge on identical weights each keep their own model artifact (integrity_report /
  # holdout_spent_at), instead of the later save upserting over the earlier one's audit record.
  # Explicit short index name — the default would exceed Postgres' 63-char identifier limit.
  def up do
    drop unique_index(:prediction_models, [:source_key, :weights_hash, :model_version])

    create unique_index(
             :prediction_models,
             [:source_key, :weights_hash, :model_version, :prereg_id],
             name: :prediction_models_artifact_uniq
           )
  end

  def down do
    drop unique_index(
           :prediction_models,
           [:source_key, :weights_hash, :model_version, :prereg_id],
           name: :prediction_models_artifact_uniq
         )

    create unique_index(:prediction_models, [:source_key, :weights_hash, :model_version])
  end
end
