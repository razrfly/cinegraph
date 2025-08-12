defmodule Cinegraph.Repo.Migrations.DropImportStateTable do
  use Ecto.Migration

  def up do
    # Migrate any existing data from import_state to api_lookup_metrics
    # This SQL will only run if the import_state table exists
    execute("""
      INSERT INTO api_lookup_metrics (
        source, 
        operation, 
        target_identifier, 
        success, 
        metadata, 
        response_time_ms,
        inserted_at, 
        updated_at
      )
      SELECT 
        'tmdb' as source,
        'import_state' as operation,
        key as target_identifier,
        true as success,
        json_build_object(
          'value', value,
          'operation_type', 'migrated_from_import_state',
          'migrated_at', NOW()
        ) as metadata,
        0 as response_time_ms,
        updated_at as inserted_at,
        NOW() as updated_at
      FROM import_state
      WHERE EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'import_state')
      AND NOT EXISTS (
        SELECT 1 FROM api_lookup_metrics 
        WHERE source = 'tmdb' 
        AND operation = 'import_state' 
        AND target_identifier = import_state.key
      )
    """)
    
    # Drop the import_state table (will fail silently if it doesn't exist)
    execute("DROP TABLE IF EXISTS import_state")
  end

  def down do
    # Recreate the import_state table if needed
    create table(:import_state, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :text
      add :updated_at, :utc_datetime_usec, null: false
    end
    
    # Migrate data back from api_lookup_metrics
    execute("""
      INSERT INTO import_state (key, value, updated_at)
      SELECT 
        target_identifier as key,
        metadata->>'value' as value,
        inserted_at as updated_at
      FROM api_lookup_metrics
      WHERE operation = 'import_state'
      AND source = 'tmdb'
      AND metadata->>'operation_type' = 'migrated_from_import_state'
    """)
    
    IO.puts("Recreated import_state table and restored data")
  end
end