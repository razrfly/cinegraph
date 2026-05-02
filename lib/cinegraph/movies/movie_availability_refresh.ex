defmodule Cinegraph.Movies.MovieAvailabilityRefresh do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cinegraph.Movies.WatchProvider

  @valid_statuses ~w(success no_results error)

  schema "movie_availability_refreshes" do
    belongs_to :movie, Cinegraph.Movies.Movie

    field :region, :string
    field :source, :string, default: "tmdb"
    field :status, :string
    field :error_reason, :string
    field :tmdb_link, :string
    field :fetched_at, :utc_datetime
    field :stale_after, :utc_datetime
    field :metadata, :map, default: %{}

    timestamps()
  end

  @required_fields [:movie_id, :region, :source, :status, :fetched_at, :stale_after]
  @optional_fields [:error_reason, :tmdb_link, :metadata]

  def changeset(refresh, attrs) do
    refresh
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:source, WatchProvider.valid_sources())
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_length(:region, is: 2)
    |> foreign_key_constraint(:movie_id)
    |> unique_constraint([:movie_id, :region, :source],
      name: :movie_availability_refresh_unique_idx
    )
  end

  def valid_statuses, do: @valid_statuses
end
