defmodule Cinegraph.Cultural.OscarCategory do
  use Ecto.Schema
  import Ecto.Changeset

  schema "oscar_categories" do
    field :name, :string
    field :category_type, :string # 'person', 'film', 'technical'
    field :is_major, :boolean, default: false
    field :tracks_person, :boolean, default: false
    
    has_many :nominations, Cinegraph.Cultural.OscarNomination, foreign_key: :category_id
    
    timestamps()
  end

  @doc false
  def changeset(oscar_category, attrs) do
    oscar_category
    |> cast(attrs, [:name, :category_type, :is_major, :tracks_person])
    |> validate_required([:name, :category_type])
    |> validate_inclusion(:category_type, ["person", "film", "technical"])
    |> unique_constraint(:name)
  end
end