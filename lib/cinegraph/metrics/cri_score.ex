defmodule Cinegraph.Metrics.CRIScore do
  @moduledoc """
  Schema for computed CRI scores per movie and weight profile.
  Stores dimension scores and final CRI score with explanations.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Metrics.WeightProfile

  schema "cri_scores" do
    belongs_to :movie, Movie
    belongs_to :profile, WeightProfile
    
    # Dimension scores
    field :timelessness_score, :float
    field :cultural_penetration_score, :float
    field :artistic_impact_score, :float
    field :institutional_score, :float
    field :public_score, :float
    
    # Final CRI
    field :total_cri_score, :float
    field :percentile_rank, :float
    
    # For analysis
    field :is_in_1001_list, :boolean
    field :predicted_in_1001, :boolean
    
    field :explain, :map
    
    timestamps(updated_at: false)
  end

  @required_fields ~w(movie_id profile_id total_cri_score)a
  @optional_fields ~w(timelessness_score cultural_penetration_score artistic_impact_score
                     institutional_score public_score percentile_rank
                     is_in_1001_list predicted_in_1001 explain)a

  def changeset(cri_score, attrs) do
    cri_score
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_scores()
    |> unique_constraint([:movie_id, :profile_id])
  end

  defp validate_scores(changeset) do
    changeset
    |> validate_number(:timelessness_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:cultural_penetration_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:artistic_impact_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:institutional_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:public_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:total_cri_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:percentile_rank, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 100.0)
  end
end