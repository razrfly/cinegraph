defmodule Cinegraph.Metrics.WeightProfile do
  @moduledoc """
  Schema for weight profiles - different scoring strategies.
  Includes CRI dimension weights and per-metric weights.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "weight_profiles" do
    field :name, :string
    field :description, :string
    field :profile_type, :string
    
    # CRI Dimension weights (must sum to 1.0)
    field :timelessness_weight, :float, default: 0.2
    field :cultural_penetration_weight, :float, default: 0.2
    field :artistic_impact_weight, :float, default: 0.2
    field :institutional_weight, :float, default: 0.2
    field :public_weight, :float, default: 0.2
    
    # Per-metric weights
    field :metric_weights, :map, default: %{}
    
    # Backtesting results
    field :backtest_score, :float
    field :precision_score, :float
    field :recall_score, :float
    field :f1_score, :float
    
    # ML metadata
    field :training_method, :string
    field :training_iterations, :integer
    field :training_date, :utc_datetime
    field :training_params, :map
    
    field :active, :boolean, default: true
    field :is_default, :boolean, default: false
    field :is_system, :boolean, default: false
    
    # TODO: belongs_to :user, User when users table exists
    
    has_many :cri_scores, Cinegraph.Metrics.CRIScore, foreign_key: :profile_id
    
    timestamps()
  end

  @required_fields ~w(name profile_type)a
  @optional_fields ~w(description timelessness_weight cultural_penetration_weight 
                     artistic_impact_weight institutional_weight public_weight
                     metric_weights backtest_score precision_score recall_score f1_score
                     training_method training_iterations training_date training_params
                     active is_default is_system)a
  
  @profile_types ~w(manual ml_derived hybrid)
  @training_methods ~w(gradient_descent genetic_algorithm manual)

  def changeset(weight_profile, attrs) do
    weight_profile
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:profile_type, @profile_types)
    |> validate_inclusion(:training_method, @training_methods, allow_nil: true)
    |> validate_dimension_weights()
    |> validate_backtest_scores()
    |> unique_constraint(:name)
    |> check_constraint(:dimension_weights_sum,
        name: :dimension_weights_sum_to_one,
        message: "dimension weights must sum to 1.0")
  end

  defp validate_dimension_weights(changeset) do
    changeset
    |> validate_number(:timelessness_weight, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:cultural_penetration_weight, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:artistic_impact_weight, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:institutional_weight, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:public_weight, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_weights_sum_to_one()
  end

  defp validate_weights_sum_to_one(changeset) do
    weights = [
      get_field(changeset, :timelessness_weight) || 0.2,
      get_field(changeset, :cultural_penetration_weight) || 0.2,
      get_field(changeset, :artistic_impact_weight) || 0.2,
      get_field(changeset, :institutional_weight) || 0.2,
      get_field(changeset, :public_weight) || 0.2
    ]
    
    sum = Enum.sum(weights)
    
    if abs(sum - 1.0) > 0.001 do
      add_error(changeset, :timelessness_weight, "dimension weights must sum to 1.0 (currently #{sum})")
    else
      changeset
    end
  end

  defp validate_backtest_scores(changeset) do
    changeset
    |> validate_number(:backtest_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 100.0)
    |> validate_number(:precision_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:recall_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:f1_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
  end

  def profile_types, do: @profile_types
  def training_methods, do: @training_methods
end