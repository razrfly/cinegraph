defmodule Cinegraph.Repo.Migrations.AddCollaborationTables do
  use Ecto.Migration

  def change do
    # Main collaboration summary table (consolidated)
    create table(:collaborations) do
      add :person_a_id, references(:people, on_delete: :delete_all), null: false
      add :person_b_id, references(:people, on_delete: :delete_all), null: false

      # Core metrics
      add :collaboration_count, :integer, null: false, default: 0
      add :first_collaboration_date, :date
      add :latest_collaboration_date, :date
      add :avg_movie_rating, :decimal, precision: 3, scale: 1
      add :total_revenue, :bigint, default: 0

      # Yearly metrics (denormalized for performance)
      add :years_active, {:array, :integer}, default: []
      add :peak_year, :integer

      # Diversity metrics
      add :genre_diversity_score, :decimal, precision: 3, scale: 2
      add :role_diversity_score, :decimal, precision: 3, scale: 2

      timestamps(type: :timestamptz)
    end

    # Constraints to prevent duplicates
    create constraint(:collaborations, :ordered_persons, check: "person_a_id < person_b_id")
    create unique_index(:collaborations, [:person_a_id, :person_b_id])

    # Essential indexes for performance (unique index already covers person_a_id, person_b_id)
    create index(:collaborations, [:person_b_id, :person_a_id])
    create index(:collaborations, [:collaboration_count])
    create index(:collaborations, [:first_collaboration_date, :latest_collaboration_date])
    create index(:collaborations, [:total_revenue], where: "total_revenue > 0")

    # Detailed collaboration data (normalized)
    create table(:collaboration_details) do
      add :collaboration_id, references(:collaborations, on_delete: :delete_all), null: false
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      # 'actor-actor', 'actor-director', etc.
      add :collaboration_type, :string, null: false
      add :year, :integer, null: false

      # Movie-specific data
      add :movie_rating, :decimal, precision: 3, scale: 1
      add :movie_revenue, :bigint
    end

    # Ensure no duplicate entries
    create unique_index(:collaboration_details, [
             :collaboration_id,
             :movie_id,
             :collaboration_type
           ])

    # Indexes for details table
    create index(:collaboration_details, :collaboration_id)
    create index(:collaboration_details, :movie_id)
    create index(:collaboration_details, :year)
    create index(:collaboration_details, :collaboration_type)

    # Person relationship cache for six degrees queries
    create table(:person_relationships) do
      add :from_person_id, references(:people, on_delete: :delete_all), null: false
      add :to_person_id, references(:people, on_delete: :delete_all), null: false
      add :degree, :integer, null: false
      add :path_count, :integer, default: 1
      add :shortest_path, {:array, :integer}, null: false

      # Additional metrics
      add :strongest_connection_score, :decimal, precision: 5, scale: 2
      add :calculated_at, :timestamptz, default: fragment("NOW()")
      add :expires_at, :timestamptz, default: fragment("NOW() + interval '7 days'")
    end

    # Prevent duplicates
    create unique_index(:person_relationships, [:from_person_id, :to_person_id])
    create index(:person_relationships, [:degree, :from_person_id])
    create index(:person_relationships, :expires_at)

    # Add constraint to ensure degree is between 1 and 6
    create constraint(:person_relationships, :valid_degree, check: "degree BETWEEN 1 AND 6")

    # Create a function to update timestamps
    execute """
            CREATE OR REPLACE FUNCTION update_collaboration_timestamp()
            RETURNS TRIGGER AS $$
            BEGIN
              NEW.updated_at = NOW();
              RETURN NEW;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS update_collaboration_timestamp();"

    # Create trigger for updating timestamps
    execute """
            CREATE TRIGGER update_collaboration_timestamp
            BEFORE UPDATE ON collaborations
            FOR EACH ROW
            EXECUTE FUNCTION update_collaboration_timestamp();
            """,
            "DROP TRIGGER IF EXISTS update_collaboration_timestamp ON collaborations;"

    # Helper function to ensure consistent person ordering
    execute """
            CREATE OR REPLACE FUNCTION ensure_person_order(p1_id INTEGER, p2_id INTEGER)
            RETURNS TABLE(person_a_id INTEGER, person_b_id INTEGER) AS $$
            BEGIN
              IF p1_id < p2_id THEN
                RETURN QUERY SELECT p1_id, p2_id;
              ELSE
                RETURN QUERY SELECT p2_id, p1_id;
              END IF;
            END;
            $$ LANGUAGE plpgsql IMMUTABLE;
            """,
            "DROP FUNCTION IF EXISTS ensure_person_order(INTEGER, INTEGER);"

    # Note: Materialized view will be created after data import via a separate migration
    # This prevents errors during initial setup when tables are empty
  end
end
