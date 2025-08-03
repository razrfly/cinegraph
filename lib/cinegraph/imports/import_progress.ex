defmodule Cinegraph.Imports.ImportProgress do
  @moduledoc """
  DEPRECATED: This module is kept for backwards compatibility only.
  Use ImportState and TMDbImporterV2 instead.
  
  This is a stub implementation that prevents errors in the old dashboard.
  Navigate to /imports/v2 for the new dashboard.
  """
  
  # Stub structure to prevent errors
  defstruct [
    :id,
    :import_type,
    :total_pages,
    :current_page,
    :movies_found,
    :movies_imported,
    :movies_failed,
    :started_at,
    :completed_at,
    :status,
    :metadata,
    :inserted_at,
    :updated_at
  ]
  
  # Stub methods to prevent errors in old dashboard
  
  @doc """
  DEPRECATED: Returns empty list.
  """
  def get_running do
    []
  end
  
  @doc """
  DEPRECATED: Returns nil.
  """
  def get_latest(_type) do
    nil
  end
  
  @doc """
  DEPRECATED: Returns nil.
  """
  def get(id) when is_integer(id) do
    nil
  end
  
  @doc """
  DEPRECATED: Use TMDbImporterV2.start_full_import/0 instead.
  """
  def start_import(type, attrs \\ %{}) do
    {:ok, %__MODULE__{
      id: 1,
      import_type: type,
      status: "running",
      started_at: DateTime.utc_now(),
      current_page: 0,
      total_pages: 0,
      movies_found: 0,
      movies_imported: 0,
      movies_failed: 0,
      metadata: attrs[:metadata] || %{}
    }}
  end
  
  @doc """
  DEPRECATED: No-op.
  """
  def update(progress, attrs) do
    updated = struct(progress, attrs)
    {:ok, updated}
  end
  
  @doc """
  DEPRECATED: No-op.
  """
  def update_movies_imported(%{id: _id}, count) when is_integer(count) do
    {:ok, 0}
  end
  
  @doc """
  DEPRECATED: No-op.
  """
  def complete_import(progress) do
    update(progress, %{
      status: "completed",
      completed_at: DateTime.utc_now()
    })
  end
  
  @doc """
  DEPRECATED: No-op.
  """
  def fail_import(progress, _reason) do
    update(progress, %{
      status: "failed",
      completed_at: DateTime.utc_now()
    })
  end
end