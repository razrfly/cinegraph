defmodule Cinegraph.Calibration.Reference do
  @moduledoc """
  Schema for individual movie entries in calibration reference lists.

  Each reference links an external list entry to a movie in our database,
  storing the external ranking/score and match confidence for calibration analysis.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "calibration_references" do
    field :rank, :integer
    field :external_score, :decimal
    field :external_id, :string
    field :external_title, :string
    field :external_year, :integer
    field :match_confidence, :decimal

    belongs_to :reference_list, Cinegraph.Calibration.ReferenceList
    belongs_to :movie, Cinegraph.Movies.Movie

    timestamps()
  end

  @required_fields ~w(reference_list_id)a
  @optional_fields ~w(movie_id rank external_score external_id external_title external_year match_confidence)a

  def changeset(reference, attrs) do
    reference
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:rank, greater_than: 0)
    |> validate_number(:external_score, greater_than_or_equal_to: 0, less_than_or_equal_to: 10)
    |> validate_number(:match_confidence, greater_than_or_equal_to: 0, less_than_or_equal_to: 1)
    |> foreign_key_constraint(:reference_list_id)
    |> foreign_key_constraint(:movie_id)
    |> unique_constraint([:reference_list_id, :movie_id])
    |> unique_constraint([:reference_list_id, :rank])
  end

  @doc """
  Changeset for importing references from external sources.
  """
  def import_changeset(reference, attrs) do
    reference
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required([:reference_list_id, :external_title])
    |> foreign_key_constraint(:reference_list_id)
  end
end
