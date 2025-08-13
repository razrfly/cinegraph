defmodule Cinegraph.Metrics.Metric do
  @moduledoc """
  Schema for actual metric values per movie.
  Stores both raw and normalized values for each metric.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Cinegraph.Movies.Movie

  schema "metrics" do
    belongs_to :movie, Movie
    field :metric_code, :string
    field :raw_value_numeric, :float
    field :raw_value_text, :string
    field :normalized_value, :float
    field :observed_at, :utc_datetime
    field :source_ref, :string
    
    timestamps(updated_at: false)
  end

  @required_fields ~w(movie_id metric_code normalized_value)a
  @optional_fields ~w(raw_value_numeric raw_value_text observed_at source_ref)a

  def changeset(metric, attrs) do
    metric
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:normalized_value, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_raw_value()
    |> unique_constraint([:movie_id, :metric_code])
  end

  defp validate_raw_value(changeset) do
    # Ensure at least one raw value is present
    numeric = get_field(changeset, :raw_value_numeric)
    text = get_field(changeset, :raw_value_text)
    
    if is_nil(numeric) and is_nil(text) do
      add_error(changeset, :raw_value_numeric, "either raw_value_numeric or raw_value_text must be present")
    else
      changeset
    end
  end
end