defmodule Cinegraph.Cultural.OscarCeremony do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  Schema for storing Oscar ceremony data with raw JSON from scraping.
  """

  schema "oscar_ceremonies" do
    field :ceremony_number, :integer
    field :year, :integer
    field :ceremony_date, :date
    field :data, :map

    timestamps()
  end

  @doc false
  def changeset(oscar_ceremony, attrs) do
    oscar_ceremony
    |> cast(attrs, [:ceremony_number, :year, :ceremony_date, :data])
    |> validate_required([:ceremony_number, :year, :data])
    |> unique_constraint(:year)
    |> unique_constraint(:ceremony_number)
  end
end