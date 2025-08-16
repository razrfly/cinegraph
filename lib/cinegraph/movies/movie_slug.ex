defmodule Cinegraph.Movies.MovieSlug do
  @moduledoc """
  Slug generation module for movies with intelligent conflict resolution.
  
  Primary pattern: title-year (e.g., "the-matrix-1999")
  Conflict resolution order:
    1. Try adding country code from origin_country field (e.g., "the-office-2005-us")
    2. Try adding director name from credits (e.g., "crash-1996-cronenberg")
    3. Last resort: sequential numbering
  """
  
  use EctoAutoslugField.Slug, from: [:title], to: :slug
  
  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Movies.{Movie, Credit}

  @doc """
  Dynamically determine slug sources based on the movie data.
  Always starts with title and year.
  """
  def get_sources(_changeset, _opts) do
    # We'll just use title here since build_slug will handle the year
    [:title]
  end

  @doc """
  Build slug with intelligent conflict resolution.
  Tries: title-year, then title-year-country, then title-year-director, then title-year-number
  """
  def build_slug(sources, changeset) do
    title = List.first(sources) || ""
    year = extract_year(changeset)
    
    base_slug = create_base_slug(title, year)
    
    # Check for conflicts and resolve
    resolve_conflict(base_slug, changeset)
  end

  defp create_base_slug(title, year) when is_binary(title) do
    year_str = if year, do: "#{year}", else: "unknown"
    "#{slugify_string(title)}-#{year_str}"
  end

  defp resolve_conflict(base_slug, changeset) do
    movie_id = Ecto.Changeset.get_field(changeset, :id)
    
    # Check if this exact slug exists (excluding current movie if updating)
    if slug_exists?(base_slug, movie_id) do
      add_disambiguator(base_slug, changeset, movie_id)
    else
      base_slug
    end
  end

  defp slug_exists?(slug, movie_id) do
    query = 
      from m in Movie, 
      where: m.slug == ^slug
    
    query = if movie_id do
      from m in query, where: m.id != ^movie_id
    else
      query
    end
    
    Repo.exists?(query)
  end

  defp add_disambiguator(base_slug, changeset, movie_id) do
    # First, try adding the country code if available
    country_slug = try_country_slug(base_slug, changeset, movie_id)
    if country_slug do
      country_slug
    else
      # If country doesn't work or isn't available, try director
      director_slug = try_director_slug(base_slug, changeset, movie_id)
      if director_slug do
        director_slug
      else
        # Last resort: sequential numbering
        add_sequential_number(base_slug, movie_id)
      end
    end
  end

  defp try_country_slug(base_slug, changeset, movie_id) do
    # Get the country from origin_country field (it's already an array of country codes)
    case Ecto.Changeset.get_field(changeset, :origin_country) do
      [country | _] when is_binary(country) ->
        # Just use the country code as-is, lowercased
        country_code = String.downcase(country)
        proposed_slug = "#{base_slug}-#{country_code}"
        
        if !slug_exists?(proposed_slug, movie_id) do
          proposed_slug
        else
          nil
        end
      _ ->
        nil
    end
  end

  defp try_director_slug(base_slug, changeset, movie_id) do
    # If we have a movie_id, query the database for the director
    director_name = get_director_name(changeset, movie_id)
    
    if director_name do
      # Just take the last name of the director for the slug
      director_slug = 
        director_name
        |> String.split(" ")
        |> List.last()
        |> slugify_string()
      
      proposed_slug = "#{base_slug}-#{director_slug}"
      
      if !slug_exists?(proposed_slug, movie_id) do
        proposed_slug
      else
        nil
      end
    else
      nil
    end
  end

  defp get_director_name(_changeset, movie_id) do
    # If we have a movie_id, query the database for the director
    if movie_id do
      query = from c in Credit,
        where: c.movie_id == ^movie_id and c.job == "Director",
        join: p in assoc(c, :person),
        select: p.name,
        limit: 1
      
      Repo.one(query)
    else
      # For new movies, we might not have credits yet
      nil
    end
  end

  # This should rarely be used - only as absolute last resort
  defp add_sequential_number(base_slug, movie_id) do
    pattern = "#{base_slug}-%"
    
    query = 
      from m in Movie,
      where: ilike(m.slug, ^pattern),
      select: m.slug
    
    query = if movie_id do
      from m in query, where: m.id != ^movie_id
    else
      query
    end
    
    existing_slugs = Repo.all(query)
    
    # Find the next available number
    next_number = find_next_available_number(existing_slugs, base_slug)
    "#{base_slug}-#{next_number}"
  end

  defp find_next_available_number(existing_slugs, base_slug) do
    numbers = 
      existing_slugs
      |> Enum.map(fn slug ->
        case Regex.run(~r/#{Regex.escape(base_slug)}-(\d+)$/, slug) do
          [_, num_str] -> String.to_integer(num_str)
          _ -> 0
        end
      end)
      |> Enum.filter(&(&1 > 0))
      |> Enum.sort()
    
    case numbers do
      [] -> 2
      list -> 
        # Find the first gap or use max + 1
        find_gap_or_next(list, 2)
    end
  end

  defp find_gap_or_next([], next), do: next
  defp find_gap_or_next([h | _t], next) when h > next, do: next
  defp find_gap_or_next([h | t], next) when h == next, do: find_gap_or_next(t, next + 1)
  defp find_gap_or_next([_h | t], next), do: find_gap_or_next(t, next)

  defp slugify_string(nil), do: "untitled"
  defp slugify_string(""), do: "untitled"
  defp slugify_string(string) when is_binary(string) do
    string
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[^a-z0-9\s-]/u, "")
    |> String.replace(~r/\s+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  defp extract_year(changeset) do
    case Ecto.Changeset.get_field(changeset, :release_date) do
      %Date{year: year} -> year
      _ -> nil
    end
  end
end