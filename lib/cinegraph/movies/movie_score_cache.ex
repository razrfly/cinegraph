defmodule Cinegraph.Movies.MovieScoreCache do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "movie_score_caches" do
    belongs_to :movie, Cinegraph.Movies.Movie

    # 6 lens scores (0–10)
    field :mob_score, :float
    field :critics_score, :float
    field :festival_recognition_score, :float
    field :time_machine_score, :float
    field :auteurs_score, :float
    field :box_office_score, :float

    # Derived
    field :overall_score, :float
    field :score_confidence, :float
    field :disparity_score, :float
    field :disparity_category, :string
    field :unpredictability_score, :float

    # Cache metadata
    field :calculated_at, :utc_datetime
    field :calculation_version, :string

    timestamps()
  end

  def changeset(score_cache, attrs) do
    score_cache
    |> cast(attrs, [
      :movie_id,
      :mob_score,
      :critics_score,
      :festival_recognition_score,
      :time_machine_score,
      :auteurs_score,
      :box_office_score,
      :overall_score,
      :score_confidence,
      :disparity_score,
      :disparity_category,
      :unpredictability_score,
      :calculated_at,
      :calculation_version
    ])
    |> validate_required([
      :movie_id,
      :mob_score,
      :critics_score,
      :festival_recognition_score,
      :time_machine_score,
      :auteurs_score,
      :box_office_score,
      :overall_score,
      :score_confidence,
      :calculated_at,
      :calculation_version
    ])
    |> foreign_key_constraint(:movie_id)
    |> unique_constraint(:movie_id)
  end
end
