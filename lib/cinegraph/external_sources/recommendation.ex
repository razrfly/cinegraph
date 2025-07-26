defmodule Cinegraph.ExternalSources.Recommendation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "external_recommendations" do
    belongs_to :source_movie, Cinegraph.Movies.Movie
    belongs_to :recommended_movie, Cinegraph.Movies.Movie
    belongs_to :source, Cinegraph.ExternalSources.Source
    
    field :recommendation_type, :string
    field :score, :float
    field :metadata, :map, default: %{}
    field :fetched_at, :utc_datetime
    
    timestamps()
  end

  @doc false
  def changeset(recommendation, attrs) do
    recommendation
    |> cast(attrs, [:source_movie_id, :recommended_movie_id, :source_id,
                    :recommendation_type, :score, :metadata, :fetched_at])
    |> validate_required([:source_movie_id, :recommended_movie_id, :source_id, :recommendation_type])
    |> validate_inclusion(:recommendation_type, ["similar", "recommended"])
    |> validate_number(:score, greater_than_or_equal_to: 0.0)
    |> foreign_key_constraint(:source_movie_id)
    |> foreign_key_constraint(:recommended_movie_id)
    |> foreign_key_constraint(:source_id)
    |> unique_constraint([:source_movie_id, :recommended_movie_id, :source_id, :recommendation_type])
  end
end