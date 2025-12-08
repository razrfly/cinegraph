defmodule Cinegraph.Festivals.FestivalOrganization do
  @moduledoc """
  Schema for festival organizations (Oscars, Cannes, Venice, Berlin, etc.)
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "festival_organizations" do
    field :name, :string
    field :slug, :string
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
    |> cast(attrs, [:name, :slug, :abbreviation, :country, :founded_year, :website, :metadata])
    |> validate_required([:name])
    |> maybe_generate_slug()
    |> unique_constraint(:name)
    |> unique_constraint(:abbreviation)
    |> unique_constraint(:slug)
  end

  defp maybe_generate_slug(changeset) do
    case get_field(changeset, :slug) do
      nil ->
        name = get_field(changeset, :name)
        if name, do: put_change(changeset, :slug, slugify(name)), else: changeset

      _ ->
        changeset
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.trim("-")
  end
end
