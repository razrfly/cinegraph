defmodule Cinegraph.Repo.Migrations.AddObanJobsWorkerStateCompletedIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:oban_jobs, [:worker, :state, :completed_at],
             concurrently: true,
             name: :idx_oban_jobs_worker_state_completed_at
           )
  end
end
