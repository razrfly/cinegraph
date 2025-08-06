defmodule Cinegraph.Festivals.FestivalOrganization do
  @moduledoc """
  Schema for festival organizations (Oscars, Cannes, Venice, Berlin, etc.)
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "festival_organizations" do
    field :name, :string
    field :abbreviation, :string
    field :country, :string
    field :founded_year, :integer
    field :website, :string
    field :metadata, :map, default: %{}

    has_many :ceremonies, Cinegraph.Festivals.FestivalCeremony, foreign_key: :organization_id
    has_many :categories, Cinegraph.Festivals.FestivalCategory, foreign_key: :organization_id

    timestamps()
  end

  @doc false
  def changeset(organization, attrs) do
    organization
    |> cast(attrs, [:name, :abbreviation, :country, :founded_year, :website, :metadata])
    |> validate_required([:name])
    |> unique_constraint(:name)
    |> unique_constraint(:abbreviation)
  end
end
