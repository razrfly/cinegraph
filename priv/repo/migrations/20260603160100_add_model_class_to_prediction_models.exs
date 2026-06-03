defmodule Cinegraph.Repo.Migrations.AddModelClassToPredictionModels do
  use Ecto.Migration

  # Adds the model-class discriminator (#1061 Session 1). Postgres `ADD COLUMN ... DEFAULT`
  # backfills the existing rows atomically, so the ~10 live models become "linear_logreg"
  # with no separate UPDATE — they ARE all linear logistic regression today.
  #
  # `serialized_model` is for opaque (non-weight-map) classes arriving in Session 2; weight-map
  # classes keep using `weights`. We do NOT recompute existing rows' `weights_hash`: the hash now
  # optionally includes model_class, so recomputing would change stored values and orphan the
  # active-model pointers. Existing hashes stay valid as-is.
  def up do
    alter table(:prediction_models) do
      add :model_class, :string, null: false, default: "linear_logreg"
      add :serialized_model, :map
    end
  end

  def down do
    alter table(:prediction_models) do
      remove :model_class
      remove :serialized_model
    end
  end
end
