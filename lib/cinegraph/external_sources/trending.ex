defmodule Cinegraph.ExternalSources.Trending do
  use Ecto.Schema
  import Ecto.Changeset

  schema "external_trending" do
    belongs_to :movie, Cinegraph.Movies.Movie
    belongs_to :source, Cinegraph.ExternalSources.Source
    
    field :time_window, :string
    field :rank, :integer
    field :score, :float
    field :region, :string
    field :fetched_at, :utc_datetime
    
    timestamps()
  end

  @doc false
  def changeset(trending, attrs) do
    trending
    |> cast(attrs, [:movie_id, :source_id, :time_window, :rank, :score, :region, :fetched_at])
    |> validate_required([:movie_id, :source_id, :time_window, :rank])
    |> validate_inclusion(:time_window, ["day", "week"])
    |> validate_number(:rank, greater_than: 0)
    |> validate_number(:score, greater_than_or_equal_to: 0.0)
    |> foreign_key_constraint(:movie_id)
    |> foreign_key_constraint(:source_id)
  end
end