defmodule Cinegraph.Cultural.CRIScore do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  schema "cri_scores" do
    field :overall_score, :float
    field :timelessness_score, :float
    field :cultural_penetration_score, :float
    field :artistic_impact_score, :float
    field :institutional_recognition_score, :float
    field :public_reception_score, :float
    field :calculation_version, :string
    field :calculated_at, :utc_datetime
    field :metadata, :map

    belongs_to :movie, Cinegraph.Movies.Movie, foreign_key: :movie_id

    timestamps()
  end

  @doc false
  def changeset(cri_score, attrs) do
    cri_score
    |> cast(attrs, [:movie_id, :overall_score, :timelessness_score, :cultural_penetration_score, 
                    :artistic_impact_score, :institutional_recognition_score, :public_reception_score,
                    :calculation_version, :calculated_at, :metadata])
    |> validate_required([:movie_id, :overall_score, :calculation_version, :calculated_at])
    |> validate_number(:overall_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 100.0)
    |> validate_number(:timelessness_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 100.0)
    |> validate_number(:cultural_penetration_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 100.0)
    |> validate_number(:artistic_impact_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 100.0)
    |> validate_number(:institutional_recognition_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 100.0)
    |> validate_number(:public_reception_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 100.0)
    |> foreign_key_constraint(:movie_id)
  end
end