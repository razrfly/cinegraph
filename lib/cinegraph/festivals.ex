defmodule Cinegraph.Festivals do
  @moduledoc """
  The Festivals context for managing all festival data (Oscar, Cannes, Venice, Berlin, etc.)
  This replaces the old Oscar-specific tables with unified festival tables.
  """

  import Ecto.Query, warn: false
  alias Cinegraph.Repo

  alias Cinegraph.Festivals.{
    FestivalOrganization,
    FestivalCeremony,
    FestivalCategory,
    FestivalNomination
  }

  # ========================================
  # FESTIVAL ORGANIZATIONS
  # ========================================

  @doc """
  Gets or creates the Oscar organization.
  """
  def get_or_create_oscar_organization do
    # Try to get existing first
    case Repo.get_by(FestivalOrganization, abbreviation: "AMPAS") do
      nil ->
        # Create new
        attrs = %{
          name: "Academy of Motion Picture Arts and Sciences",
          abbreviation: "AMPAS",
          country: "USA",
          founded_year: 1927,
          website: "https://www.oscars.org"
        }
        
        %FestivalOrganization{}
        |> FestivalOrganization.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, org} -> org
          {:error, _changeset} -> 
            # Race condition - try to get again
            Repo.get_by!(FestivalOrganization, abbreviation: "AMPAS")
        end
        
      existing_org ->
        existing_org
    end
  end

  @doc """
  Gets an organization by abbreviation.
  """
  def get_organization_by_abbreviation(abbrev) do
    Repo.get_by(FestivalOrganization, abbreviation: abbrev)
  end

  # ========================================
  # FESTIVAL CEREMONIES
  # ========================================

  @doc """
  Returns the list of festival ceremonies for a specific organization.
  """
  def list_ceremonies(organization_id) do
    from(c in FestivalCeremony,
      where: c.organization_id == ^organization_id,
      order_by: [desc: c.year],
      preload: [:organization]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single festival ceremony by organization and year.
  """
  def get_ceremony_by_year(organization_id, year) do
    Repo.get_by(FestivalCeremony, organization_id: organization_id, year: year)
  end

  @doc """
  Creates or updates a festival ceremony.
  """
  def upsert_ceremony(attrs) do
    %FestivalCeremony{}
    |> FestivalCeremony.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:organization_id, :year]
    )
  end

  # ========================================
  # FESTIVAL CATEGORIES
  # ========================================

  @doc """
  Gets a festival category by organization and name.
  """
  def get_category(organization_id, name) do
    Repo.get_by(FestivalCategory, organization_id: organization_id, name: name)
  end

  @doc """
  Creates a festival category.
  """
  def create_category(attrs) do
    %FestivalCategory{}
    |> FestivalCategory.changeset(attrs)
    |> Repo.insert()
  end

  # ========================================
  # FESTIVAL NOMINATIONS
  # ========================================

  @doc """
  Creates a festival nomination.
  """
  def create_nomination(attrs) do
    %FestivalNomination{}
    |> FestivalNomination.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets nominations for a ceremony.
  """
  def get_ceremony_nominations(ceremony_id) do
    from(n in FestivalNomination,
      where: n.ceremony_id == ^ceremony_id,
      preload: [:category, :movie, :person]
    )
    |> Repo.all()
  end

  @doc """
  Counts nominations by ceremony.
  """
  def count_nominations(ceremony_id) do
    from(n in FestivalNomination, where: n.ceremony_id == ^ceremony_id)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Counts wins by ceremony.
  """
  def count_wins(ceremony_id) do
    from(n in FestivalNomination, 
      where: n.ceremony_id == ^ceremony_id and n.won == true
    )
    |> Repo.aggregate(:count, :id)
  end
end