defmodule Cinegraph.ExternalSources.Rating do
  use Ecto.Schema
  import Ecto.Changeset

  schema "external_ratings" do
    belongs_to :movie, Cinegraph.Movies.Movie
    belongs_to :source, Cinegraph.ExternalSources.Source
    
    field :rating_type, :string
    field :value, :float
    field :scale_min, :float, default: 0.0
    field :scale_max, :float, default: 10.0
    field :sample_size, :integer
    field :metadata, :map, default: %{}
    field :fetched_at, :utc_datetime
    
    timestamps()
  end

  @doc false
  def changeset(rating, attrs) do
    rating
    |> cast(attrs, [:movie_id, :source_id, :rating_type, :value, 
                    :scale_min, :scale_max, :sample_size, :metadata, :fetched_at])
    |> validate_required([:movie_id, :source_id, :rating_type, :value])
    |> validate_inclusion(:rating_type, ["user", "critic", "algorithm", "popularity", "engagement", "list_appearances", "box_office", "imdb_votes"])
    |> validate_number(:value, greater_than_or_equal_to: 0.0)
    |> validate_number(:scale_min, greater_than_or_equal_to: 0.0)
    |> validate_number(:scale_max, greater_than: 0.0)
    |> foreign_key_constraint(:movie_id)
    |> foreign_key_constraint(:source_id)
    |> unique_constraint([:movie_id, :source_id, :rating_type])
  end
end