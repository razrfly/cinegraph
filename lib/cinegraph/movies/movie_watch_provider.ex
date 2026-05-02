defmodule Cinegraph.Movies.MovieWatchProvider do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cinegraph.Movies.WatchProvider

  @valid_monetization_types ~w(flatrate free ads rent buy)

  schema "movie_watch_providers" do
    belongs_to :movie, Cinegraph.Movies.Movie
    belongs_to :watch_provider, WatchProvider

    field :region, :string
    field :monetization_type, :string
    field :display_priority, :integer
    field :tmdb_link, :string
    field :source, :string, default: "tmdb"
    field :fetched_at, :utc_datetime
    field :stale_after, :utc_datetime
    field :metadata, :map, default: %{}

    timestamps()
  end

  @required_fields [
    :movie_id,
    :watch_provider_id,
    :region,
    :monetization_type,
    :source,
    :fetched_at,
    :stale_after
  ]
  @optional_fields [:display_priority, :tmdb_link, :metadata]

  def changeset(movie_watch_provider, attrs) do
    movie_watch_provider
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:source, WatchProvider.valid_sources())
    |> validate_inclusion(:monetization_type, @valid_monetization_types)
    |> validate_length(:region, is: 2)
    |> foreign_key_constraint(:movie_id)
    |> foreign_key_constraint(:watch_provider_id)
    |> unique_constraint([:movie_id, :watch_provider_id, :region, :monetization_type, :source],
      name: :movie_watch_provider_unique_idx
    )
  end

  def valid_monetization_types, do: @valid_monetization_types
end
