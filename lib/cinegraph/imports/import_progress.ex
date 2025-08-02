defmodule Cinegraph.Imports.ImportProgress do
  @moduledoc """
  Schema and context for tracking import progress.
  """
  
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, except: [update: 2]
  alias Cinegraph.Repo
  alias __MODULE__
  
  schema "import_progress" do
    field :import_type, :string
    field :total_pages, :integer
    field :current_page, :integer
    field :movies_found, :integer, default: 0
    field :movies_imported, :integer, default: 0
    field :movies_failed, :integer, default: 0
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :status, :string
    field :metadata, :map, default: %{}
    
    timestamps()
  end
  
  @required_fields [:import_type, :status, :started_at]
  @optional_fields [:total_pages, :current_page, :movies_found, :movies_imported, 
                    :movies_failed, :completed_at, :metadata]
  @valid_statuses ["running", "completed", "failed", "paused"]
  @valid_types ["full", "daily_update", "backfill", "discovery"]
  
  def changeset(progress, attrs) do
    progress
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:import_type, @valid_types)
  end
  
  # Context functions
  
  def create(attrs) do
    %ImportProgress{}
    |> changeset(attrs)
    |> Repo.insert()
  end
  
  def get(id) do
    Repo.get(ImportProgress, id)
  end
  
  def update(%ImportProgress{} = progress, attrs) do
    progress
    |> changeset(attrs)
    |> Repo.update()
  end
  
  def get_latest(import_type) do
    Repo.one(
      from p in ImportProgress,
      where: p.import_type == ^import_type,
      order_by: [desc: p.started_at],
      limit: 1
    )
  end
  
  def get_running do
    Repo.all(
      from p in ImportProgress,
      where: p.status == "running",
      order_by: [desc: p.started_at]
    )
  end
  
  def start_import(import_type, opts \\ %{}) do
    attrs = %{
      import_type: import_type,
      status: "running",
      started_at: DateTime.utc_now(),
      total_pages: opts[:total_pages],
      current_page: 0,
      metadata: opts[:metadata] || %{}
    }
    
    create(attrs)
  end
  
  def complete_import(%ImportProgress{} = progress) do
    update(progress, %{
      status: "completed",
      completed_at: DateTime.utc_now()
    })
  end
  
  def fail_import(%ImportProgress{} = progress, reason) do
    metadata = Map.put(progress.metadata || %{}, "failure_reason", to_string(reason))
    
    update(progress, %{
      status: "failed",
      completed_at: DateTime.utc_now(),
      metadata: metadata
    })
  end
end