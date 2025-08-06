defmodule Cinegraph.Events.FestivalDate do
  @moduledoc """
  Schema for specific festival dates and status tracking.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Cinegraph.Events.FestivalEvent

  schema "festival_dates" do
    belongs_to :festival_event, FestivalEvent
    
    field :year, :integer
    field :start_date, :date
    field :end_date, :date
    field :status, :string
    field :announcement_date, :date
    field :source, :string
    field :notes, :string
    field :metadata, :map

    timestamps()
  end

  @doc false
  def changeset(festival_date, attrs) do
    festival_date
    |> cast(attrs, [
      :festival_event_id, :year, :start_date, :end_date, :status,
      :announcement_date, :source, :notes, :metadata
    ])
    |> validate_required([:festival_event_id, :year, :status])
    |> validate_inclusion(:status, ["upcoming", "in_progress", "completed", "cancelled"])
    |> validate_number(:year, greater_than: 1800, less_than: 3000)
    |> validate_date_range()
    |> unique_constraint([:festival_event_id, :year])
    |> foreign_key_constraint(:festival_event_id)
  end

  defp validate_date_range(changeset) do
    start_date = get_field(changeset, :start_date)
    end_date = get_field(changeset, :end_date)
    
    if start_date && end_date && Date.compare(end_date, start_date) == :lt do
      add_error(changeset, :end_date, "must be after start date")
    else
      changeset
    end
  end
end