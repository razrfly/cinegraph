defmodule Cinegraph.Imports.SkippedImport do
  use Ecto.Schema
  import Ecto.Changeset

  schema "skipped_imports" do
    field :tmdb_id, :integer
    field :title, :string
    field :reason, :string
    field :criteria_failed, :map
    field :checked_at, :utc_datetime_usec
    
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(skipped_import, attrs) do
    skipped_import
    |> cast(attrs, [:tmdb_id, :title, :reason, :criteria_failed, :checked_at])
    |> validate_required([:tmdb_id, :reason])
  end
end