defmodule Cinegraph.Movies.WatchProviderRegion do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cinegraph.Movies.WatchProvider

  schema "watch_provider_regions" do
    field :iso_3166_1, :string
    field :english_name, :string
    field :native_name, :string
    field :source, :string, default: "tmdb"
    field :active, :boolean, default: true
    field :last_seen_at, :utc_datetime
    field :metadata, :map, default: %{}

    timestamps()
  end

  @required_fields [:iso_3166_1, :english_name, :source]
  @optional_fields [:native_name, :active, :last_seen_at, :metadata]

  def changeset(region, attrs) do
    region
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:source, WatchProvider.valid_sources())
    |> validate_length(:iso_3166_1, is: 2)
    |> unique_constraint([:source, :iso_3166_1])
  end
end
