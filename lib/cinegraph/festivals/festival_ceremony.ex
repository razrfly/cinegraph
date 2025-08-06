defmodule Cinegraph.Festivals.FestivalCeremony do
  @moduledoc """
  Schema for festival ceremonies (Oscar, Cannes, Venice, Berlin, etc.)
  Replaces the old OscarCeremony table.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "festival_ceremonies" do
    belongs_to :organization, Cinegraph.Festivals.FestivalOrganization
    field :year, :integer
    field :ceremony_number, :integer
    field :name, :string
    field :date, :date
    field :location, :string
    field :data, :map, default: %{}
    field :data_source, :string, default: "unknown"
    field :source_url, :string
    field :scraped_at, :utc_datetime
    field :source_metadata, :map, default: %{}

    has_many :nominations, Cinegraph.Festivals.FestivalNomination, foreign_key: :ceremony_id

    timestamps()
  end

  @doc false
  def changeset(ceremony, attrs) do
    ceremony
    |> cast(attrs, [
      :organization_id,
      :year,
      :ceremony_number,
      :name,
      :date,
      :location,
      :data,
      :data_source,
      :source_url,
      :scraped_at,
      :source_metadata
    ])
    |> validate_required([:organization_id, :year])
    |> foreign_key_constraint(:organization_id)
    |> unique_constraint([:organization_id, :year])
  end
end
