defmodule Cinegraph.Metrics.MetricScore do
  @moduledoc """
  Schema for calculated metric scores that are cached for performance.
  
  Stores the computed scores for each movie using different weight profiles, 
  including category breakdowns and calculation metadata.
  """
  
  use Ecto.Schema
  import Ecto.Changeset
  
  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id
  
  schema "metric_scores" do
    # Foreign keys
    belongs_to :movie, Cinegraph.Movies.Movie
    belongs_to :profile, Cinegraph.Metrics.MetricWeightProfile
    
    # Category scores
    field :ratings_score, :float  # Normalized aggregate of all ratings
    field :awards_score, :float   # Normalized aggregate of all awards
    field :financial_score, :float # Normalized aggregate of financial metrics
    field :cultural_score, :float  # Normalized aggregate of cultural list inclusions
    
    # Total weighted score
    field :total_score, :float
    
    # Raw metric values used (for transparency)
    field :metric_values, :map  # {"imdb_rating": 8.3, "oscar_wins": 7, ...}
    
    # Metadata
    field :percentile_rank, :float  # Where this movie ranks in the distribution
    field :calculated_at, :utc_datetime
    field :metrics_available, :integer  # Number of metrics available for this movie
    field :metrics_missing, {:array, :string}  # List of missing metric codes
    
    timestamps()
  end
  
  @required_fields [:movie_id, :profile_id, :total_score, :calculated_at]
  @optional_fields [:ratings_score, :awards_score, :financial_score, :cultural_score,
                    :metric_values, :percentile_rank, :metrics_available, :metrics_missing]
  
  @doc false
  def changeset(metric_score, attrs) do
    metric_score
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:movie_id)
    |> foreign_key_constraint(:profile_id)
    |> unique_constraint([:movie_id, :profile_id])
    |> validate_number(:total_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_category_scores()
  end
  
  defp validate_category_scores(changeset) do
    changeset
    |> validate_number(:ratings_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0, allow_nil: true)
    |> validate_number(:awards_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0, allow_nil: true)
    |> validate_number(:financial_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0, allow_nil: true)
    |> validate_number(:cultural_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0, allow_nil: true)
    |> validate_number(:percentile_rank, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 100.0, allow_nil: true)
  end
end