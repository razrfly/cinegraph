defmodule Cinegraph.Movies.FailedImdbLookup do
  use Ecto.Schema
  import Ecto.Changeset

  schema "failed_imdb_lookups" do
    field :imdb_id, :string
    field :title, :string
    field :year, :integer
    field :source, :string
    field :source_key, :string
    field :reason, :string
    field :metadata, :map, default: %{}
    field :retry_count, :integer, default: 0
    field :last_retry_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(failed_lookup, attrs) do
    failed_lookup
    |> cast(attrs, [:imdb_id, :title, :year, :source, :source_key, :reason, :metadata, :retry_count, :last_retry_at])
    |> validate_required([:imdb_id, :source, :reason])
    |> unique_constraint([:imdb_id, :source, :source_key])
  end
end