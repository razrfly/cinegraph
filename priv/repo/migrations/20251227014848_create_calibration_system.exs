defmodule Cinegraph.Repo.Migrations.CreateCalibrationSystem do
  use Ecto.Migration

  def change do
    # Reference lists for calibration (IMDb Top 250, 1001 Movies, AFI 100, etc.)
    create table(:calibration_reference_lists) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text
      add :source_url, :text
      add :list_type, :string, default: "ranked"
      add :total_items, :integer
      add :last_synced_at, :utc_datetime

      timestamps()
    end

    create unique_index(:calibration_reference_lists, [:slug])
    create index(:calibration_reference_lists, [:name])

    # Individual movie entries in reference lists
    create table(:calibration_references) do
      add :reference_list_id, references(:calibration_reference_lists, on_delete: :delete_all),
        null: false

      add :movie_id, references(:movies, on_delete: :nilify_all)
      add :rank, :integer
      add :external_score, :decimal, precision: 5, scale: 2
      add :external_id, :string
      add :external_title, :string
      add :external_year, :integer
      add :match_confidence, :decimal, precision: 3, scale: 2

      timestamps()
    end

    create index(:calibration_references, [:reference_list_id])
    create index(:calibration_references, [:movie_id])
    create unique_index(:calibration_references, [:reference_list_id, :movie_id])

    create unique_index(:calibration_references, [:reference_list_id, :rank],
             where: "rank IS NOT NULL"
           )

    # Scoring configuration versions with full history
    create table(:calibration_scoring_configurations) do
      add :version, :integer, null: false
      add :name, :string, null: false
      add :description, :text
      add :is_active, :boolean, default: false
      add :is_draft, :boolean, default: true

      add :category_weights, :map,
        null: false,
        default: %{
          "popular_opinion" => 0.20,
          "industry_recognition" => 0.20,
          "cultural_impact" => 0.20,
          "people_quality" => 0.20,
          "financial_performance" => 0.20
        }

      add :normalization_method, :string, default: "none"
      add :normalization_settings, :map, default: %{}

      add :missing_data_strategies, :map,
        default: %{
          "popular_opinion" => "neutral",
          "industry_recognition" => "exclude",
          "cultural_impact" => "neutral",
          "people_quality" => "average",
          "financial_performance" => "exclude"
        }

      add :deployed_at, :utc_datetime

      timestamps()
    end

    create unique_index(:calibration_scoring_configurations, [:version])
    create index(:calibration_scoring_configurations, [:is_active])
    create index(:calibration_scoring_configurations, [:is_draft])

    create unique_index(:calibration_scoring_configurations, [:is_active],
             where: "is_active = true",
             name: :calibration_scoring_configurations_single_active
           )
  end
end
