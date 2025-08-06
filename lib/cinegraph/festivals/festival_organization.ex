defmodule Cinegraph.Festivals.FestivalOrganization do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
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
  def changeset(festival_organization, attrs) do
    festival_organization
    |> cast(attrs, [:name, :abbreviation, :country, :founded_year, :website, :metadata])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end