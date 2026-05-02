defmodule Cinegraph.Movies.WatchProvider do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_sources ~w(tmdb justwatch)

  schema "watch_providers" do
    field :source, :string, default: "tmdb"
    field :source_provider_id, :string
    field :tmdb_provider_id, :integer
    field :name, :string
    field :logo_path, :string
    field :display_priorities, :map, default: %{}
    field :active, :boolean, default: true
    field :last_seen_at, :utc_datetime
    field :metadata, :map, default: %{}

    has_many :movie_watch_providers, Cinegraph.Movies.MovieWatchProvider

    timestamps()
  end

  @required_fields [:source, :source_provider_id, :name]
  @optional_fields [
    :tmdb_provider_id,
    :logo_path,
    :display_priorities,
    :active,
    :last_seen_at,
    :metadata
  ]

  def changeset(provider, attrs) do
    provider
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:source, @valid_sources)
    |> unique_constraint([:source, :source_provider_id])
  end

  def valid_sources, do: @valid_sources
end
