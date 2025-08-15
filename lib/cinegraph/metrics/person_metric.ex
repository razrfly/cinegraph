defmodule Cinegraph.Metrics.PersonMetric do
  @moduledoc """
  Schema for person quality metrics.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "person_metrics" do
    belongs_to :person, Cinegraph.Movies.Person, foreign_key: :person_id, type: :id
    field :metric_type, :string
    field :score, :float
    field :components, :map, default: %{}
    field :metadata, :map, default: %{}
    field :calculated_at, :utc_datetime
    field :valid_until, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(person_id metric_type score calculated_at)a
  @optional_fields ~w(components metadata valid_until)a

  def changeset(person_metric, attrs) do
    person_metric
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:score, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_inclusion(:metric_type, [
      "quality_score",          # Universal person quality score
      "director_quality",       # Legacy - for backward compatibility
      "actor_quality",          # Legacy - for backward compatibility
      "writer_quality",         # Legacy - for backward compatibility
      "producer_quality",       # Legacy - for backward compatibility
      "awards_score",
      "career_longevity",
      "peer_recognition",
      "cultural_impact"
    ])
    |> unique_constraint([:person_id, :metric_type], name: :person_metrics_person_id_metric_type_index)
    |> check_constraint(:score, name: :score_range)
  end
end