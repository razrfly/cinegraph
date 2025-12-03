defmodule Cinegraph.Repo.Migrations.AddObanJobsQueueIndex do
  use Ecto.Migration

  @moduledoc """
  Add standalone queue index on oban_jobs table.
  PlanetScale recommendation #31.

  Supports queries that filter by queue without state filtering.
  """

  def change do
    create index(:oban_jobs, [:queue], name: :idx_oban_jobs_on_queue)
  end
end
