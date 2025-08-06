defmodule Cinegraph.Festivals.FestivalCeremony do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "festival_ceremonies" do
    field :year, :integer
    field :ceremony_number, :integer
    field :name, :string
    field :date, :date
    field :location, :string
    field :data, :map, default: %{}

    belongs_to :organization, Cinegraph.Festivals.FestivalOrganization
    has_many :nominations, Cinegraph.Festivals.FestivalNomination, foreign_key: :ceremony_id

    timestamps()
  end

  @doc false
  def changeset(festival_ceremony, attrs) do
    festival_ceremony
    |> cast(attrs, [:organization_id, :year, :ceremony_number, :name, :date, :location, :data])
    |> validate_required([:organization_id, :year])
    |> foreign_key_constraint(:organization_id)
    |> unique_constraint([:organization_id, :year])
  end
end