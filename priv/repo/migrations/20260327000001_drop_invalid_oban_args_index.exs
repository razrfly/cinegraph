defmodule Cinegraph.Repo.Migrations.DropInvalidObanArgsIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # oban_jobs_args_index_ccnew is an INVALID GIN index — a failed CONCURRENTLY
    # rebuild that never completed. It wastes space and has no query benefit.
    execute "DROP INDEX CONCURRENTLY IF EXISTS oban_jobs_args_index_ccnew"
  end

  def down do
    raise "irreversible migration: cannot restore dropped invalid oban args index"
  end
end
