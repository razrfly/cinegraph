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
    FestivalNomination,
    AwardImportStatus
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
          {:ok, org} ->
            org

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
    Repo.replica().get_by(FestivalOrganization, abbreviation: abbrev)
  end

  @doc """
  Gets an organization by slug.
  """
  def get_organization_by_slug(slug) do
    Repo.replica().get_by(FestivalOrganization, slug: slug)
  end

  @doc """
  Lists all festival organizations.
  """
  def list_organizations do
    from(o in FestivalOrganization,
      order_by: [asc: o.name]
    )
    |> Repo.replica().all()
  end

  @doc """
  Counts movies with nominations/wins for an organization.
  """
  def count_movies_for_organization(organization_id) do
    from(n in FestivalNomination,
      join: c in FestivalCeremony,
      on: n.ceremony_id == c.id,
      where: c.organization_id == ^organization_id,
      where: not is_nil(n.movie_id),
      select: count(n.movie_id, :distinct)
    )
    |> Repo.replica().one()
  end

  @doc """
  Counts winners for an organization.
  """
  def count_winners_for_organization(organization_id) do
    from(n in FestivalNomination,
      join: c in FestivalCeremony,
      on: n.ceremony_id == c.id,
      where: c.organization_id == ^organization_id,
      where: n.won == true,
      where: not is_nil(n.movie_id),
      select: count(n.movie_id, :distinct)
    )
    |> Repo.replica().one()
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
  Gets a category by name for a specific organization.
  """
  def get_category_by_name(organization_id, name) do
    Repo.replica().get_by(FestivalCategory, organization_id: organization_id, name: name)
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
    |> Repo.replica().all()
  end

  @doc """
  Gets a single festival ceremony by organization and year.
  """
  def get_ceremony_by_year(organization_id, year) do
    Repo.replica().get_by(FestivalCeremony, organization_id: organization_id, year: year)
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
    Repo.replica().get_by(FestivalCategory, organization_id: organization_id, name: name)
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
    case %FestivalNomination{}
         |> FestivalNomination.changeset(attrs)
         |> Repo.insert() do
      {:ok, nomination} = result ->
        # Trigger PQS recalculation for festival nominations
        if nomination.ceremony_id do
          Cinegraph.Metrics.PQSTriggerStrategy.trigger_festival_import_completion(
            nomination.ceremony_id
          )
        end

        result

      error ->
        error
    end
  end

  @doc """
  Deletes a nomination by ID.
  Returns {:ok, nomination} or {:error, reason}.

  Used by the admin audit interface to remove incorrect nominations.
  """
  def delete_nomination(nomination_id) do
    case Repo.get(FestivalNomination, nomination_id) do
      nil ->
        {:error, :not_found}

      nomination ->
        case Repo.delete(nomination) do
          {:ok, deleted} ->
            require Logger

            Logger.info(
              "Deleted nomination #{nomination_id} (movie_id: #{nomination.movie_id}, ceremony_id: #{nomination.ceremony_id})"
            )

            {:ok, deleted}

          error ->
            error
        end
    end
  end

  @doc """
  Gets a single nomination by ID with preloaded associations.
  """
  def get_nomination(nomination_id) do
    Repo.get(FestivalNomination, nomination_id)
    |> Repo.preload([:category, :movie, :person, :ceremony])
  end

  @doc """
  Switches a nomination to a different movie.
  Returns {:ok, updated_nomination} or {:error, changeset}.

  Used by the admin audit interface to correct incorrectly linked movies.
  """
  def switch_nomination_movie(nomination_id, new_movie_id) do
    case Repo.get(FestivalNomination, nomination_id) do
      nil ->
        {:error, :not_found}

      nomination ->
        old_movie_id = nomination.movie_id

        nomination
        |> FestivalNomination.changeset(%{movie_id: new_movie_id})
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            require Logger

            Logger.info(
              "Switched nomination #{nomination_id}: movie #{old_movie_id} → #{new_movie_id}"
            )

            {:ok, Repo.preload(updated, [:category, :movie, :person, :ceremony], force: true)}

          error ->
            error
        end
    end
  end

  @doc """
  Finds candidate movies by title for switching.
  Returns movies matching the title, ordered by release date proximity to ceremony year.

  ## Options

  - `:limit` - Maximum number of results (default: 10)

  ## Examples

      find_candidate_movies("Nosferatu", 2025)
      find_candidate_movies("The Godfather", 1973, limit: 20)

  """
  def find_candidate_movies(title, ceremony_year, opts \\ []) do
    alias Cinegraph.Movies.Movie

    limit = Keyword.get(opts, :limit, 10)
    # Most festivals honor films from the previous year
    eligible_year = ceremony_year - 1

    clean_title = String.trim(title)

    from(m in Movie,
      where:
        fragment("LOWER(?) LIKE LOWER(?)", m.title, ^"%#{clean_title}%") or
          fragment("LOWER(?) LIKE LOWER(?)", m.original_title, ^"%#{clean_title}%"),
      select: %{
        id: m.id,
        title: m.title,
        original_title: m.original_title,
        tmdb_id: m.tmdb_id,
        imdb_id: m.imdb_id,
        release_date: m.release_date,
        slug: m.slug,
        poster_path: m.poster_path,
        year_diff:
          fragment(
            "ABS(EXTRACT(YEAR FROM ?)::integer - ?)",
            m.release_date,
            ^eligible_year
          )
      },
      order_by: [
        asc: fragment("ABS(EXTRACT(YEAR FROM ?)::integer - ?)", m.release_date, ^eligible_year)
      ],
      limit: ^limit
    )
    |> Repo.replica().all()
  end

  @doc """
  Gets nominations for a ceremony.
  """
  def get_ceremony_nominations(ceremony_id) do
    from(n in FestivalNomination,
      where: n.ceremony_id == ^ceremony_id,
      preload: [:category, :movie, :person]
    )
    |> Repo.replica().all()
  end

  @doc """
  Gets all nominations for a ceremony with full movie/person details,
  grouped by category for the audit interface.

  Returns a map where keys are category names and values are lists of nominations.
  Nominations within each category are ordered by winner status (winners first), then by movie title.
  """
  def get_ceremony_nominations_for_audit(ceremony_id) do
    from(n in FestivalNomination,
      where: n.ceremony_id == ^ceremony_id,
      join: c in assoc(n, :category),
      join: m in assoc(n, :movie),
      left_join: p in assoc(n, :person),
      preload: [category: c, movie: m, person: p],
      order_by: [asc: c.name, desc: n.won, asc: m.title]
    )
    |> Repo.replica().all()
    |> Enum.group_by(& &1.category.name)
    |> Enum.sort_by(fn {category_name, _} -> category_name end)
    |> Enum.into(%{})
  end

  @doc """
  Gets the list of unique category names for a ceremony.
  Useful for populating filter dropdowns.
  """
  def get_ceremony_categories(ceremony_id) do
    from(n in FestivalNomination,
      where: n.ceremony_id == ^ceremony_id,
      join: c in assoc(n, :category),
      select: c.name,
      distinct: true,
      order_by: [asc: c.name]
    )
    |> Repo.replica().all()
  end

  @doc """
  Counts nominations by ceremony.
  """
  def count_nominations(ceremony_id) do
    from(n in FestivalNomination, where: n.ceremony_id == ^ceremony_id)
    |> Repo.replica().aggregate(:count, :id)
  end

  @doc """
  Counts wins by ceremony.
  """
  def count_wins(ceremony_id) do
    from(n in FestivalNomination,
      where: n.ceremony_id == ^ceremony_id and n.won == true
    )
    |> Repo.replica().aggregate(:count, :id)
  end

  # ========================================
  # AWARD IMPORT STATUS (VIEW-BACKED)
  # ========================================

  @doc """
  Lists all award import statuses from the view.

  Returns data from the `award_import_status` PostgreSQL view which aggregates
  import status across all festival organizations and ceremonies.

  ## Options

  - `:organization_id` - Filter by specific organization
  - `:status` - Filter by status (e.g., "completed", "pending", "not_started")
  - `:year_range` - Filter by year range as `{start_year, end_year}`

  ## Examples

      # Get all import statuses
      list_award_import_statuses()

      # Get statuses for a specific organization
      list_award_import_statuses(organization_id: 1)

      # Get only completed imports
      list_award_import_statuses(status: "completed")

      # Get imports for years 2020-2024
      list_award_import_statuses(year_range: {2020, 2024})

  """
  def list_award_import_statuses(opts \\ []) do
    organization_id = Keyword.get(opts, :organization_id)
    status = Keyword.get(opts, :status)
    year_range = Keyword.get(opts, :year_range)

    query = from(s in AwardImportStatus)

    query =
      if organization_id do
        from(s in query, where: s.organization_id == ^organization_id)
      else
        query
      end

    query =
      if status do
        from(s in query, where: s.status == ^status)
      else
        query
      end

    query =
      case year_range do
        {start_year, end_year} ->
          from(s in query, where: s.year >= ^start_year and s.year <= ^end_year)

        _ ->
          query
      end

    from(s in query, order_by: [asc: s.abbreviation, desc: s.year])
    |> Repo.replica().all()
  end

  @doc """
  Gets award import statuses grouped by organization.

  Returns a map where keys are organization abbreviations and values are
  lists of import status records for that organization.
  """
  def list_award_import_statuses_by_organization(opts \\ []) do
    list_award_import_statuses(opts)
    |> Enum.group_by(& &1.abbreviation)
  end

  @doc """
  Gets a single award import status record by organization ID.

  This is useful for looking up festival information from synthetic (negative)
  organization IDs generated by the award_import_status view for festivals
  that don't have an organization record yet.

  Returns the first status record for the organization, or nil if not found.
  """
  def get_award_import_status_by_org_id(organization_id) do
    Repo.replica().one(
      from(s in AwardImportStatus,
        where: s.organization_id == ^organization_id,
        order_by: [desc: s.year],
        limit: 1
      )
    )
  end

  @doc """
  Gets import status summary statistics.

  Returns a map with aggregate statistics across all (or filtered) import statuses:

  - `:total_organizations` - Number of distinct organizations
  - `:total_ceremonies` - Number of ceremonies with data
  - `:total_nominations` - Sum of all nominations
  - `:total_matched` - Sum of all matched movies
  - `:by_status` - Count of ceremonies by status
  - `:overall_match_rate` - Aggregate match rate percentage

  ## Options

  Same as `list_award_import_statuses/1`
  """
  def get_award_import_summary(opts \\ []) do
    statuses = list_award_import_statuses(opts)

    # Filter out rows without ceremonies (not_started records)
    with_ceremonies = Enum.filter(statuses, &(&1.ceremony_id != nil))

    total_nominations =
      with_ceremonies
      |> Enum.map(& &1.total_nominations)
      |> Enum.sum()

    total_matched =
      with_ceremonies
      |> Enum.map(& &1.matched_movies)
      |> Enum.sum()

    overall_match_rate =
      if total_nominations > 0 do
        Float.round(total_matched / total_nominations * 100, 1)
      else
        0.0
      end

    by_status =
      statuses
      |> Enum.group_by(& &1.status)
      |> Enum.map(fn {status, items} -> {status, length(items)} end)
      |> Enum.into(%{})

    %{
      total_organizations: statuses |> Enum.map(& &1.organization_id) |> Enum.uniq() |> length(),
      total_ceremonies: length(with_ceremonies),
      total_nominations: total_nominations,
      total_matched: total_matched,
      overall_match_rate: overall_match_rate,
      by_status: by_status
    }
  end

  @doc """
  Gets import status for a specific organization and year.
  """
  def get_award_import_status(organization_id, year) do
    from(s in AwardImportStatus,
      where: s.organization_id == ^organization_id and s.year == ^year
    )
    |> Repo.replica().one()
  end

  @doc """
  Gets the year range with available data for an organization.

  Returns `{min_year, max_year}` or `nil` if no data exists.
  """
  def get_organization_year_range(organization_id) do
    from(s in AwardImportStatus,
      where: s.organization_id == ^organization_id and not is_nil(s.ceremony_id),
      select: {min(s.year), max(s.year)}
    )
    |> Repo.replica().one()
    |> case do
      {nil, nil} -> nil
      range -> range
    end
  end

  # ========================================
  # IMPORT STATUS TRACKING HELPERS
  # ========================================

  @doc """
  Updates the import status metadata for a ceremony.

  Merges the provided status updates into the existing `source_metadata` JSONB field.
  This is used by import workers to track progress, errors, and completion state.

  ## Examples

      update_ceremony_import_status(ceremony, %{
        "import_status" => "completed",
        "nominations_found" => 45,
        "completed_at" => DateTime.utc_now()
      })

  """
  def update_ceremony_import_status(%FestivalCeremony{} = ceremony, status_updates)
      when is_map(status_updates) do
    new_metadata = Map.merge(ceremony.source_metadata || %{}, stringify_keys(status_updates))

    ceremony
    |> FestivalCeremony.changeset(%{source_metadata: new_metadata})
    |> Repo.update()
  end

  @doc """
  Marks a ceremony import as started.

  Updates source_metadata with:
  - `import_status` = "in_progress"
  - `job_id` = the Oban job ID
  - `started_at` = current timestamp
  """
  def mark_import_started(%FestivalCeremony{} = ceremony, job_id) do
    update_ceremony_import_status(ceremony, %{
      "import_status" => "in_progress",
      "job_id" => job_id,
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  @doc """
  Marks a ceremony import as completed.

  Updates source_metadata with:
  - `import_status` = "completed"
  - `nominations_found` = count from stats
  - `nominations_matched` = matched count from stats
  - `completed_at` = current timestamp
  - `last_error` = nil (clears any previous error)

  ## Options

  The `stats` map should contain:
  - `:nominations_found` - total nominations imported
  - `:nominations_matched` - nominations that matched to movies (optional)
  - `:winners_count` - number of winners (optional)
  """
  def mark_import_completed(%FestivalCeremony{} = ceremony, stats \\ %{}) do
    update_ceremony_import_status(ceremony, %{
      "import_status" => "completed",
      "nominations_found" => Map.get(stats, :nominations_found, 0),
      "nominations_matched" => Map.get(stats, :nominations_matched),
      "winners_count" => Map.get(stats, :winners_count),
      "completed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "last_error" => nil
    })
  end

  @doc """
  Marks a ceremony import as failed.

  Updates source_metadata with:
  - `import_status` = "failed"
  - `last_error` = error message/reason
  - `retry_count` = incremented from previous value
  - `failed_at` = current timestamp
  """
  def mark_import_failed(%FestivalCeremony{} = ceremony, error) do
    current_retry_count = get_in(ceremony.source_metadata || %{}, ["retry_count"]) || 0

    update_ceremony_import_status(ceremony, %{
      "import_status" => "failed",
      "last_error" => format_error(error),
      "retry_count" => current_retry_count + 1,
      "failed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  # Helper to stringify map keys for JSONB storage
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list) do
    Enum.map(list, &stringify_keys/1)
  end

  defp stringify_keys(value), do: value

  # Helper to format errors for storage
  defp format_error(error) when is_binary(error), do: error
  defp format_error(%{message: msg}), do: msg
  defp format_error(error), do: inspect(error, limit: 200)
end
