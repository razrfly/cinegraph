defmodule Cinegraph.Collaborations.CollaborationDetail do
  use Ecto.Schema
  import Ecto.Changeset

  schema "collaboration_details" do
    belongs_to :collaboration, Cinegraph.Collaborations.Collaboration
    belongs_to :movie, Cinegraph.Movies.Movie
    field :collaboration_type, :string
    field :year, :integer
    field :movie_rating, :decimal
    field :movie_revenue, :integer
  end

  @doc false
  def changeset(detail, attrs) do
    detail
    |> cast(attrs, [:collaboration_id, :movie_id, :collaboration_type, 
                    :year, :movie_rating, :movie_revenue])
    |> validate_required([:collaboration_id, :movie_id, :collaboration_type, :year])
    |> validate_inclusion(:collaboration_type, 
         ["actor-actor", "actor-director", "director-director", "actor-producer", 
          "director-producer", "other"])
    |> foreign_key_constraint(:collaboration_id)
    |> foreign_key_constraint(:movie_id)
    |> unique_constraint([:collaboration_id, :movie_id, :collaboration_type])
  end
end