defmodule Cinegraph.Festivals.FestivalCategory do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "festival_categories" do
    field :name, :string
    field :tracks_person, :boolean, default: false
    field :category_type, :string # 'film', 'person', 'technical', 'special'
    field :metadata, :map, default: %{}

    belongs_to :organization, Cinegraph.Festivals.FestivalOrganization
    has_many :nominations, Cinegraph.Festivals.FestivalNomination, foreign_key: :category_id

    timestamps()
  end

  @doc false
  def changeset(festival_category, attrs) do
    festival_category
    |> cast(attrs, [:organization_id, :name, :tracks_person, :category_type, :metadata])
    |> validate_required([:organization_id, :name])
    |> validate_inclusion(:category_type, ["film", "person", "technical", "special"])
    |> foreign_key_constraint(:organization_id)
    |> unique_constraint([:organization_id, :name])
  end
end