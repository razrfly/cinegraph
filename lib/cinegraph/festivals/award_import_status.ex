defmodule Cinegraph.Festivals.AwardImportStatus do
  @moduledoc """
  Read-only schema backed by the `award_import_status` PostgreSQL view.

  This view aggregates data from festival_organizations, festival_ceremonies,
  and festival_nominations to provide a unified view of award import status
  for the admin dashboard.

  ## Status Values

  - `not_started` - No ceremony record exists for this organization/year
  - `pending` - Ceremony exists but hasn't been scraped yet
  - `empty` - Ceremony scraped but no nominations found
  - `completed` - 90%+ of nominations have matched movies
  - `partial` - 50-89% of nominations have matched movies
  - `low_match` - Less than 50% matched, but some matches exist
  - `no_matches` - Nominations exist but none matched to movies
  """
  use Ecto.Schema

  @primary_key false
  schema "award_import_status" do
    field :organization_id, :integer
    field :organization_name, :string
    field :abbreviation, :string
    field :ceremony_id, :integer
    field :year, :integer
    field :ceremony_date, :date
    field :data_source, :string
    field :source_url, :string
    field :scraped_at, :utc_datetime
    field :source_metadata, :map
    field :total_nominations, :integer
    field :matched_movies, :integer
    field :matched_people, :integer
    field :winners, :integer
    field :movie_match_rate, :decimal
    field :status, :string
    field :years_discovered_at, :utc_datetime
    field :created_at, :naive_datetime
    field :updated_at, :naive_datetime
  end

  @doc """
  Returns all valid status values.
  """
  def statuses do
    ~w(not_started pending empty completed partial low_match no_matches)
  end

  @doc """
  Returns a human-readable label for a status.
  """
  def status_label("not_started"), do: "Not Started"
  def status_label("pending"), do: "Pending"
  def status_label("empty"), do: "Empty"
  def status_label("completed"), do: "Completed"
  def status_label("partial"), do: "Partial"
  def status_label("low_match"), do: "Low Match"
  def status_label("no_matches"), do: "No Matches"
  def status_label(_), do: "Unknown"

  @doc """
  Returns a color class for a status (for UI display).
  """
  def status_color("not_started"), do: "gray"
  def status_color("pending"), do: "yellow"
  def status_color("empty"), do: "orange"
  def status_color("completed"), do: "green"
  def status_color("partial"), do: "blue"
  def status_color("low_match"), do: "amber"
  def status_color("no_matches"), do: "red"
  def status_color(_), do: "gray"
end
