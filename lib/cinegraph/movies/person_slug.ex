defmodule Cinegraph.Movies.PersonSlug do
  @moduledoc """
  Slug generation module for people (actors, directors, crew) with intelligent conflict resolution.

  Uses Cinegraph.Slugs.SlugUtils for proper Unicode transliteration:
  - Chinese names: "成龍" → "cheng-long"
  - Cyrillic names: "Андрей Тарковский" → "andrei-tarkovskii"
  - Japanese names: "黒澤明" → "hei-ze-ming"

  Primary pattern: name (e.g., "tom-hanks")
  Conflict resolution order:
    1. Try adding birth year (e.g., "michael-jackson-1958")
    2. Try adding country from place_of_birth (e.g., "michael-jackson-us")
    3. Last resort: tmdb-{id} (e.g., "tmdb-31")
  """

  use EctoAutoslugField.Slug, from: [:name], to: :slug

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Person
  alias Cinegraph.Slugs.SlugUtils

  @doc """
  Dynamically determine slug sources based on the person data.
  """
  def get_sources(_changeset, _opts) do
    [:name]
  end

  @doc """
  Build slug with intelligent conflict resolution.
  Tries: name, then name-year, then name-country, then tmdb-id
  """
  def build_slug(sources, changeset) do
    name = List.first(sources) || ""
    base_slug = SlugUtils.slugify(name)

    # Check for conflicts and resolve
    resolve_conflict(base_slug, changeset)
  end

  defp resolve_conflict(base_slug, changeset) do
    person_id = Ecto.Changeset.get_field(changeset, :id)

    if slug_exists?(base_slug, person_id) do
      add_disambiguator(base_slug, changeset, person_id)
    else
      base_slug
    end
  end

  defp slug_exists?(slug, person_id) do
    query =
      from p in Person,
        where: p.slug == ^slug

    query =
      if person_id do
        from p in query, where: p.id != ^person_id
      else
        query
      end

    Repo.exists?(query)
  end

  defp add_disambiguator(base_slug, changeset, person_id) do
    # First, try adding the birth year if available
    year_slug = try_year_slug(base_slug, changeset, person_id)

    if year_slug do
      year_slug
    else
      # If year doesn't work or isn't available, try country
      country_slug = try_country_slug(base_slug, changeset, person_id)

      if country_slug do
        country_slug
      else
        # Last resort: tmdb-{id}
        create_tmdb_fallback_slug(changeset)
      end
    end
  end

  defp try_year_slug(base_slug, changeset, person_id) do
    case Ecto.Changeset.get_field(changeset, :birthday) do
      %Date{year: year} ->
        proposed_slug = "#{base_slug}-#{year}"

        if !slug_exists?(proposed_slug, person_id) do
          proposed_slug
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp try_country_slug(base_slug, changeset, person_id) do
    case Ecto.Changeset.get_field(changeset, :place_of_birth) do
      place when is_binary(place) and byte_size(place) > 0 ->
        country_code = extract_country_code(place)

        if country_code do
          proposed_slug = "#{base_slug}-#{country_code}"

          if !slug_exists?(proposed_slug, person_id) do
            proposed_slug
          else
            nil
          end
        else
          nil
        end

      _ ->
        nil
    end
  end

  # Extract country code from place_of_birth string
  # Examples: "New York City, New York, USA" → "us"
  #           "London, England, UK" → "uk"
  #           "Tokyo, Japan" → "jp"
  defp extract_country_code(place_of_birth) do
    # Get the last part after comma, which is usually the country
    country =
      place_of_birth
      |> String.split(",")
      |> List.last()
      |> String.trim()
      |> String.downcase()

    # Map common country names to ISO codes
    country_mapping = %{
      "usa" => "us",
      "united states" => "us",
      "united states of america" => "us",
      "u.s.a." => "us",
      "u.s." => "us",
      "uk" => "uk",
      "united kingdom" => "uk",
      "england" => "uk",
      "scotland" => "uk",
      "wales" => "uk",
      "northern ireland" => "uk",
      "canada" => "ca",
      "australia" => "au",
      "japan" => "jp",
      "china" => "cn",
      "south korea" => "kr",
      "korea" => "kr",
      "france" => "fr",
      "germany" => "de",
      "italy" => "it",
      "spain" => "es",
      "mexico" => "mx",
      "brazil" => "br",
      "india" => "in",
      "russia" => "ru",
      "sweden" => "se",
      "norway" => "no",
      "denmark" => "dk",
      "netherlands" => "nl",
      "belgium" => "be",
      "switzerland" => "ch",
      "austria" => "at",
      "poland" => "pl",
      "ireland" => "ie",
      "new zealand" => "nz",
      "argentina" => "ar",
      "south africa" => "za",
      "hong kong" => "hk",
      "taiwan" => "tw",
      "singapore" => "sg",
      "thailand" => "th",
      "indonesia" => "id",
      "philippines" => "ph",
      "malaysia" => "my",
      "vietnam" => "vn",
      "israel" => "il",
      "turkey" => "tr",
      "egypt" => "eg",
      "nigeria" => "ng",
      "kenya" => "ke",
      "ussr" => "su",
      "soviet union" => "su",
      "czechoslovakia" => "cs",
      "west germany" => "de",
      "east germany" => "de"
    }

    Map.get(country_mapping, country)
  end

  defp create_tmdb_fallback_slug(changeset) do
    case Ecto.Changeset.get_field(changeset, :tmdb_id) do
      nil ->
        # If no tmdb_id, use the database id
        case Ecto.Changeset.get_field(changeset, :id) do
          nil -> "person-#{:rand.uniform(999_999)}"
          id -> "person-#{id}"
        end

      tmdb_id ->
        SlugUtils.create_fallback_slug("tmdb", tmdb_id)
    end
  end
end
