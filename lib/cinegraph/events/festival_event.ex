defmodule Cinegraph.Events.FestivalEvent do
  @moduledoc """
  Schema for festival events (Cannes, Oscars, Venice, Berlin, etc.)
  Database-driven replacement for hardcoded @event_mappings.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Cinegraph.Events.FestivalDate

  schema "festival_events" do
    # Basic Info
    field :source_key, :string
    field :name, :string
    field :abbreviation, :string
    field :country, :string
    field :founded_year, :integer
    field :website, :string
    
    # Multi-Source Configuration
    field :primary_source, :string
    field :source_config, :map
    field :fallback_sources, {:array, :map}
    
    # Date Management
    field :typical_start_month, :integer
    field :typical_start_day, :integer
    field :typical_duration_days, :integer
    field :timezone, :string
    
    # Year Range Management
    field :min_available_year, :integer
    field :max_available_year, :integer
    field :current_year_status, :string
    
    # Import Configuration
    field :active, :boolean
    field :import_priority, :integer
    field :auto_detect_new_years, :boolean
    
    # Statistics & Reliability
    field :last_successful_import, :utc_datetime
    field :total_successful_imports, :integer
    field :reliability_score, :float
    field :last_error, :string
    
    # Event Type Classification
    field :ceremony_vs_festival, :string
    field :tracks_nominations, :boolean
    field :tracks_winners_only, :boolean
    field :categories_structure, :string
    
    # Metadata
    field :metadata, :map

    has_many :dates, FestivalDate, foreign_key: :festival_event_id

    timestamps()
  end

  @doc false
  def changeset(festival_event, attrs) do
    festival_event
    |> cast(attrs, [
      :source_key, :name, :abbreviation, :country, :founded_year, :website,
      :primary_source, :source_config, :fallback_sources,
      :typical_start_month, :typical_start_day, :typical_duration_days, :timezone,
      :min_available_year, :max_available_year, :current_year_status,
      :active, :import_priority, :auto_detect_new_years,
      :last_successful_import, :total_successful_imports, :reliability_score, :last_error,
      :ceremony_vs_festival, :tracks_nominations, :tracks_winners_only, :categories_structure,
      :metadata
    ])
    |> validate_required([:source_key, :name, :primary_source])
    |> validate_inclusion(:primary_source, ["imdb", "official", "api", "custom"])
    |> validate_inclusion(:ceremony_vs_festival, ["ceremony", "festival"], allow_nil: true)
    |> validate_inclusion(:current_year_status, ["upcoming", "in_progress", "completed", "cancelled"], allow_nil: true)
    |> validate_inclusion(:categories_structure, ["hierarchical", "flat", "custom"], allow_nil: true)
    |> validate_number(:reliability_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_month_if_present()
    |> validate_day_if_present()
    |> unique_constraint(:source_key)
  end

  defp validate_month_if_present(changeset) do
    case get_field(changeset, :typical_start_month) do
      nil -> changeset
      _month -> validate_number(changeset, :typical_start_month, greater_than_or_equal_to: 1, less_than_or_equal_to: 12)
    end
  end

  defp validate_day_if_present(changeset) do
    case get_field(changeset, :typical_start_day) do
      nil -> changeset
      _day -> validate_number(changeset, :typical_start_day, greater_than_or_equal_to: 1, less_than_or_equal_to: 31)
    end
  end

  @doc """
  Convert FestivalEvent to the format expected by legacy scrapers.
  This ensures backward compatibility with existing scraper interfaces.
  """
  def to_scraper_config(%__MODULE__{} = event) do
    base_config = %{
      event_id: get_in(event.source_config, ["event_id"]) || get_in(event.source_config, ["imdb_event_id"]),
      name: event.name,
      abbreviation: event.abbreviation,
      country: event.country,
      founded_year: event.founded_year,
      website: event.website
    }
    
    # Add source-specific configuration
    Map.merge(base_config, event.source_config || %{})
  end
end