defmodule Cinegraph.Movies.MovieScoreability do
  @moduledoc """
  Read-only Ecto schema for the movie scoreability view.

  The view converts the existing score cache into the public display contract:
  whether a movie can show a numeric CineGraph score, how confident that score is,
  and which score should be used for sorting.
  """

  use Ecto.Schema

  @primary_key {:movie_id, :id, autogenerate: false}
  schema "movie_scoreability_view" do
    belongs_to :movie, Cinegraph.Movies.Movie,
      define_field: false,
      foreign_key: :movie_id,
      references: :id

    field :title, :string
    field :slug, :string
    field :release_date, :date

    field :raw_cinegraph_score, :float
    field :legacy_score_confidence, :float
    field :mob_score, :float
    field :critics_score, :float
    field :festival_recognition_score, :float
    field :time_machine_score, :float
    field :auteurs_score, :float
    field :box_office_score, :float

    field :present_lens_count, :integer
    field :missing_lens_count, :integer
    field :present_lens_labels, {:array, :string}
    field :missing_lens_labels, {:array, :string}
    field :evidence_confidence, :decimal

    field :scoreability_state, :string
    field :score_confidence_label, :string
    field :cinegraph_display_score, :float
    field :cinegraph_sort_score, :float
    field :cohort_percentile, :float
    field :score_hidden_reason, :string
    field :score_explanation_short, :string
    field :score_explanation_detail, :string

    field :calculated_at, :utc_datetime
    field :updated_at, :utc_datetime
  end
end
