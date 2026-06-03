defmodule Cinegraph.Repo.Migrations.DropCalibrationTables do
  use Ecto.Migration

  # #1036 Session 2: retire the orphaned Cinegraph.Calibration fork (versioned scoring
  # configs + reference lists duplicated movie_lists/canonical_sources). Its recall-vs-
  # reference (recall@K) algorithm is preserved in git history for the Session 3 static
  # backtest. Tables dropped here; modules/route/UI removed in the same change.
  def up do
    drop_if_exists table(:calibration_references)
    drop_if_exists table(:calibration_reference_lists)
    drop_if_exists table(:calibration_scoring_configurations)
  end

  # Shells for rollback (data is not restored; re-import from movie_lists if ever needed).
  def down do
    create table(:calibration_reference_lists) do
      add :name, :string
      add :slug, :string
      add :description, :text
      add :source_url, :text
      add :list_type, :string
      add :total_items, :integer
      add :last_synced_at, :utc_datetime
      timestamps()
    end

    create table(:calibration_references) do
      add :reference_list_id, references(:calibration_reference_lists, on_delete: :delete_all)
      add :movie_id, references(:movies, on_delete: :nilify_all)
      add :rank, :integer
      add :external_score, :decimal
      add :external_id, :string
      add :external_title, :string
      add :external_year, :integer
      add :match_confidence, :decimal
      timestamps()
    end

    create table(:calibration_scoring_configurations) do
      add :version, :integer
      add :name, :string
      add :description, :text
      add :is_active, :boolean, default: false
      add :is_draft, :boolean, default: true
      add :category_weights, :map
      add :normalization_method, :string
      add :normalization_settings, :map
      add :missing_data_strategies, :map
      add :deployed_at, :utc_datetime
      timestamps()
    end
  end
end
