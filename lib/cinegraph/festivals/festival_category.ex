defmodule Cinegraph.Festivals.FestivalCategory do
  @moduledoc """
  Schema for festival award categories.
  Replaces the old OscarCategory table.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "festival_categories" do
    belongs_to :organization, Cinegraph.Festivals.FestivalOrganization
    field :name, :string
    field :tracks_person, :boolean, default: false
    field :category_type, :string
    field :metadata, :map, default: %{}

    has_many :nominations, Cinegraph.Festivals.FestivalNomination, foreign_key: :category_id

    timestamps()
  end

  @doc false
  def changeset(category, attrs) do
    category
    |> cast(attrs, [:organization_id, :name, :tracks_person, :category_type, :metadata])
    |> validate_required([:organization_id, :name])
    |> foreign_key_constraint(:organization_id)
    |> unique_constraint([:organization_id, :name])
  end
end