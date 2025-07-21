defmodule Cinegraph.Cultural.CRIScore do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  schema "cri_scores" do
    field :score, :float
    field :components, :map
    field :version, :string
    field :calculated_at, :utc_datetime

    belongs_to :movie, Cinegraph.Movies.Movie, foreign_key: :movie_id

    timestamps()
  end

  @doc false
  def changeset(cri_score, attrs) do
    cri_score
    |> cast(attrs, [:movie_id, :score, :components, :version, :calculated_at])
    |> validate_required([:movie_id, :score, :version])
    |> validate_number(:score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 100.0)
    |> foreign_key_constraint(:movie_id)
  end
end