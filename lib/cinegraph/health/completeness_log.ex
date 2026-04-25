defmodule Cinegraph.Health.CompletenessLog do
  @moduledoc """
  One row per day capturing a completeness snapshot. Backs the 30-day
  trend chart on `/admin/health` and the `mix cinegraph.completeness` task.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:captured_on, :date, autogenerate: false}
  schema "completeness_log" do
    field :payload, :map

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(log, attrs) do
    log
    |> cast(attrs, [:captured_on, :payload])
    |> validate_required([:captured_on, :payload])
    |> unique_constraint(:captured_on)
  end
end
