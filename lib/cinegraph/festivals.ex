defmodule Cinegraph.Festivals do
  @moduledoc """
  The Festivals context - unified interface for all film festival awards.
  """

  import Ecto.Query, warn: false
  alias Cinegraph.Repo

  alias Cinegraph.Festivals.{
    FestivalOrganization,
    FestivalCeremony,
    FestivalCategory,
    FestivalNomination
  }

  # Organizations

  @doc """
  Returns the list of festival organizations.
  """
  def list_organizations do
    Repo.all(FestivalOrganization)
  end

  @doc """
  Gets a single festival organization by ID or name.
  """
  def get_organization!(id) when is_integer(id) do
    Repo.get!(FestivalOrganization, id)
  end

  def get_organization_by_name(name) do
    Repo.get_by(FestivalOrganization, name: name)
  end

  def get_organization_by_abbreviation(abbrev) do
    Repo.get_by(FestivalOrganization, abbreviation: abbrev)
  end

  @doc """
  Creates a festival organization.
  """
  def create_organization(attrs \\ %{}) do
    %FestivalOrganization{}
    |> FestivalOrganization.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a festival organization.
  """
  def update_organization(%FestivalOrganization{} = organization, attrs) do
    organization
    |> FestivalOrganization.changeset(attrs)
    |> Repo.update()
  end

  # Ceremonies

  @doc """
  Returns the list of ceremonies for an organization.
  """
  def list_ceremonies(organization_id) do
    from(c in FestivalCeremony,
      where: c.organization_id == ^organization_id,
      order_by: [desc: c.year]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single ceremony.
  """
  def get_ceremony!(id), do: Repo.get!(FestivalCeremony, id)

  @doc """
  Gets a ceremony by organization and year.
  """
  def get_ceremony_by_year(organization_id, year) do
    Repo.get_by(FestivalCeremony, organization_id: organization_id, year: year)
  end

  @doc """
  Creates a ceremony.
  """
  def create_ceremony(attrs \\ %{}) do
    %FestivalCeremony{}
    |> FestivalCeremony.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a ceremony.
  """
  def update_ceremony(%FestivalCeremony{} = ceremony, attrs) do
    ceremony
    |> FestivalCeremony.changeset(attrs)
    |> Repo.update()
  end

  # Categories

  @doc """
  Returns the list of categories for an organization.
  """
  def list_categories(organization_id) do
    from(c in FestivalCategory,
      where: c.organization_id == ^organization_id,
      order_by: c.name
    )
    |> Repo.all()
  end

  @doc """
  Gets a single category.
  """
  def get_category!(id), do: Repo.get!(FestivalCategory, id)

  @doc """
  Gets a category by organization and name.
  """
  def get_category_by_name(organization_id, name) do
    Repo.get_by(FestivalCategory, organization_id: organization_id, name: name)
  end

  @doc """
  Creates a category.
  """
  def create_category(attrs \\ %{}) do
    %FestivalCategory{}
    |> FestivalCategory.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a category.
  """
  def update_category(%FestivalCategory{} = category, attrs) do
    category
    |> FestivalCategory.changeset(attrs)
    |> Repo.update()
  end

  # Nominations

  @doc """
  Returns the list of nominations for a ceremony.
  """
  def list_nominations(ceremony_id) do
    from(n in FestivalNomination,
      where: n.ceremony_id == ^ceremony_id,
      preload: [:category, :movie, :person]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single nomination.
  """
  def get_nomination!(id) do
    FestivalNomination
    |> Repo.get!(id)
    |> Repo.preload([:ceremony, :category, :movie, :person])
  end

  @doc """
  Creates a nomination.
  """
  def create_nomination(attrs \\ %{}) do
    %FestivalNomination{}
    |> FestivalNomination.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a nomination.
  """
  def update_nomination(%FestivalNomination{} = nomination, attrs) do
    nomination
    |> FestivalNomination.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a nomination.
  """
  def delete_nomination(%FestivalNomination{} = nomination) do
    Repo.delete(nomination)
  end

  # Helper functions

  @doc """
  Find or create an organization by name.
  """
  def find_or_create_organization(attrs) do
    case get_organization_by_name(attrs.name || attrs["name"]) do
      nil -> create_organization(attrs)
      org -> {:ok, org}
    end
  end

  @doc """
  Find or create a ceremony for an organization and year.
  """
  def find_or_create_ceremony(organization_id, year, attrs \\ %{}) do
    case get_ceremony_by_year(organization_id, year) do
      nil -> 
        attrs = Map.merge(attrs, %{organization_id: organization_id, year: year})
        create_ceremony(attrs)
      ceremony -> 
        {:ok, ceremony}
    end
  end

  @doc """
  Find or create a category for an organization.
  """
  def find_or_create_category(organization_id, name, attrs \\ %{}) do
    case get_category_by_name(organization_id, name) do
      nil ->
        attrs = Map.merge(attrs, %{organization_id: organization_id, name: name})
        create_category(attrs)
      category ->
        {:ok, category}
    end
  end

  @doc """
  Get all awards for a movie across all festivals.
  """
  def get_movie_awards(movie_id) do
    from(n in FestivalNomination,
      where: n.movie_id == ^movie_id,
      join: c in assoc(n, :ceremony),
      join: cat in assoc(n, :category),
      join: o in assoc(c, :organization),
      preload: [ceremony: {c, organization: o}, category: cat],
      order_by: [desc: c.year]
    )
    |> Repo.all()
  end

  @doc """
  Get all awards for a person across all festivals.
  """
  def get_person_awards(person_id) do
    from(n in FestivalNomination,
      where: n.person_id == ^person_id,
      join: c in assoc(n, :ceremony),
      join: cat in assoc(n, :category),
      join: o in assoc(c, :organization),
      preload: [ceremony: {c, organization: o}, category: cat, movie: :movie],
      order_by: [desc: c.year]
    )
    |> Repo.all()
  end

  @doc """
  Count nominations by organization.
  """
  def count_nominations_by_organization do
    from(n in FestivalNomination,
      join: c in assoc(n, :ceremony),
      join: o in assoc(c, :organization),
      group_by: [o.id, o.name],
      select: {o.name, count(n.id)}
    )
    |> Repo.all()
    |> Enum.into(%{})
  end

  @doc """
  Initialize standard festival organizations.
  """
  def seed_festival_organizations do
    organizations = [
      %{
        name: "Academy of Motion Picture Arts and Sciences",
        abbreviation: "AMPAS",
        country: "United States",
        founded_year: 1927,
        website: "https://www.oscars.org"
      },
      %{
        name: "Cannes Film Festival",
        abbreviation: "Cannes",
        country: "France",
        founded_year: 1946,
        website: "https://www.festival-cannes.com"
      },
      %{
        name: "Venice International Film Festival",
        abbreviation: "Venice",
        country: "Italy",
        founded_year: 1932,
        website: "https://www.labiennale.org/en/cinema"
      },
      %{
        name: "Berlin International Film Festival",
        abbreviation: "Berlinale",
        country: "Germany",
        founded_year: 1951,
        website: "https://www.berlinale.de"
      }
    ]

    Enum.map(organizations, &find_or_create_organization/1)
  end
end