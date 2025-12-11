defmodule CinegraphWeb.SEO do
  @moduledoc """
  SEO components for JSON-LD structured data, Open Graph meta tags, and other SEO-related functionality.

  Implements Schema.org structured data for:
  - Movie (https://schema.org/Movie)
  - Person (https://schema.org/Person)
  - BreadcrumbList (https://schema.org/BreadcrumbList)
  - ItemList (https://schema.org/ItemList)
  """

  use Phoenix.Component
  import Phoenix.HTML, only: [raw: 1]

  @tmdb_image_base "https://image.tmdb.org/t/p"
  @site_url "https://cinegraph.io"

  # =============================================================================
  # JSON-LD Script Component
  # =============================================================================

  @doc """
  Renders a JSON-LD script tag with the given structured data.
  """
  attr :data, :map, required: true

  def json_ld(assigns) do
    ~H"""
    <script type="application/ld+json">
      <%= raw(Jason.encode!(@data, pretty: false)) %>
    </script>
    """
  end

  # =============================================================================
  # Movie Schema
  # =============================================================================

  @doc """
  Generates JSON-LD structured data for a Movie.

  ## Example
      <.json_ld data={CinegraphWeb.SEO.movie_schema(movie)} />
  """
  def movie_schema(movie, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, @site_url)

    %{
      "@context" => "https://schema.org",
      "@type" => "Movie",
      "name" => movie.title,
      "url" => "#{base_url}/movies/#{movie.slug}"
    }
    |> maybe_add("alternateName", movie.original_title, movie.original_title != movie.title)
    |> maybe_add("description", movie.overview)
    |> maybe_add("datePublished", format_date(movie.release_date))
    |> maybe_add("duration", format_duration(movie.runtime))
    |> maybe_add("image", poster_url(movie.poster_path, "w500"))
    |> maybe_add("inLanguage", movie.original_language)
    |> maybe_add_directors(movie)
    |> maybe_add_actors(movie)
    |> maybe_add_genres(movie)
    |> maybe_add_aggregate_rating(movie)
    |> maybe_add_production_company(movie)
    |> maybe_add_country_of_origin(movie)
    |> maybe_add("sameAs", build_same_as_urls(movie))
  end

  defp maybe_add_directors(schema, movie) do
    directors = get_directors(movie)

    if directors != [] do
      Map.put(schema, "director", Enum.map(directors, &person_reference/1))
    else
      schema
    end
  end

  defp maybe_add_actors(schema, movie) do
    actors = get_actors(movie)

    if actors != [] do
      Map.put(schema, "actor", Enum.map(actors, &person_reference/1))
    else
      schema
    end
  end

  defp maybe_add_genres(schema, movie) do
    genres = get_genres(movie)

    if genres != [] do
      Map.put(schema, "genre", genres)
    else
      schema
    end
  end

  defp maybe_add_aggregate_rating(schema, movie) do
    case get_rating(movie) do
      {rating, count} when rating > 0 and count > 0 ->
        Map.put(schema, "aggregateRating", %{
          "@type" => "AggregateRating",
          "ratingValue" => rating,
          "bestRating" => 10,
          "worstRating" => 0,
          "ratingCount" => count
        })

      _ ->
        schema
    end
  end

  defp maybe_add_production_company(schema, movie) do
    case get_production_companies(movie) do
      [company | _] ->
        Map.put(schema, "productionCompany", %{
          "@type" => "Organization",
          "name" => company
        })

      _ ->
        schema
    end
  end

  defp maybe_add_country_of_origin(schema, movie) do
    case movie.origin_country do
      [country | _] when is_binary(country) ->
        Map.put(schema, "countryOfOrigin", %{
          "@type" => "Country",
          "name" => country
        })

      _ ->
        schema
    end
  end

  # =============================================================================
  # Person Schema
  # =============================================================================

  @doc """
  Generates JSON-LD structured data for a Person.

  ## Example
      <.json_ld data={CinegraphWeb.SEO.person_schema(person)} />
  """
  def person_schema(person, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, @site_url)

    %{
      "@context" => "https://schema.org",
      "@type" => "Person",
      "name" => person.name,
      "url" => "#{base_url}/people/#{person.slug}"
    }
    |> maybe_add("image", profile_url(person.profile_path, "w500"))
    |> maybe_add("birthDate", format_date(person.birthday))
    |> maybe_add("deathDate", format_date(person.deathday))
    |> maybe_add("birthPlace", person.place_of_birth)
    |> maybe_add("description", truncate_bio(person.biography))
    |> maybe_add("jobTitle", person.known_for_department)
    |> maybe_add("sameAs", build_person_same_as_urls(person))
    |> maybe_add_known_for(person)
  end

  defp maybe_add_known_for(schema, person) do
    known_for = get_known_for_movies(person)

    if known_for != [] do
      Map.put(
        schema,
        "knowsAbout",
        Enum.map(known_for, fn movie ->
          %{
            "@type" => "Movie",
            "name" => movie.title
          }
        end)
      )
    else
      schema
    end
  end

  # =============================================================================
  # BreadcrumbList Schema
  # =============================================================================

  @doc """
  Generates JSON-LD structured data for breadcrumb navigation.

  ## Example
      <.json_ld data={CinegraphWeb.SEO.breadcrumb_schema([
        {"Home", "/"},
        {"Movies", "/movies"},
        {"The Godfather", "/movies/the-godfather-1972"}
      ])} />
  """
  def breadcrumb_schema(items, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, @site_url)

    %{
      "@context" => "https://schema.org",
      "@type" => "BreadcrumbList",
      "itemListElement" =>
        items
        |> Enum.with_index(1)
        |> Enum.map(fn {{name, path}, position} ->
          %{
            "@type" => "ListItem",
            "position" => position,
            "name" => name,
            "item" => "#{base_url}#{path}"
          }
        end)
    }
  end

  # =============================================================================
  # ItemList Schema (for movie lists, search results, etc.)
  # =============================================================================

  @doc """
  Generates JSON-LD structured data for a list of items.

  ## Example
      <.json_ld data={CinegraphWeb.SEO.item_list_schema(movies, "Top Rated Movies")} />
  """
  def item_list_schema(items, name, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, @site_url)
    item_type = Keyword.get(opts, :item_type, :movie)

    %{
      "@context" => "https://schema.org",
      "@type" => "ItemList",
      "name" => name,
      "numberOfItems" => length(items),
      "itemListElement" =>
        items
        |> Enum.with_index(1)
        |> Enum.map(fn {item, position} ->
          %{
            "@type" => "ListItem",
            "position" => position,
            "item" => item_reference(item, item_type, base_url)
          }
        end)
    }
  end

  defp item_reference(item, :movie, base_url) do
    %{
      "@type" => "Movie",
      "name" => item.title,
      "url" => "#{base_url}/movies/#{item.slug}"
    }
    |> maybe_add("image", poster_url(item.poster_path, "w342"))
    |> maybe_add("datePublished", format_date(item.release_date))
  end

  defp item_reference(item, :person, base_url) do
    %{
      "@type" => "Person",
      "name" => item.name,
      "url" => "#{base_url}/people/#{item.slug}"
    }
    |> maybe_add("image", profile_url(item.profile_path, "w185"))
  end

  # =============================================================================
  # WebSite Schema (for homepage)
  # =============================================================================

  @doc """
  Generates JSON-LD structured data for the website (homepage).
  """
  def website_schema(opts \\ []) do
    base_url = Keyword.get(opts, :base_url, @site_url)

    %{
      "@context" => "https://schema.org",
      "@type" => "WebSite",
      "name" => "Cinegraph",
      "url" => base_url,
      "description" =>
        "Discover movies, explore film industry relationships, and track awards data.",
      "potentialAction" => %{
        "@type" => "SearchAction",
        "target" => %{
          "@type" => "EntryPoint",
          "urlTemplate" => "#{base_url}/movies?search={search_term_string}"
        },
        "query-input" => "required name=search_term_string"
      }
    }
  end

  # =============================================================================
  # Helper Functions
  # =============================================================================

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, _key, ""), do: map
  defp maybe_add(map, _key, []), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)

  defp maybe_add(map, _key, _value, false), do: map
  defp maybe_add(map, key, value, true), do: Map.put(map, key, value)

  defp format_date(nil), do: nil
  defp format_date(%Date{} = date), do: Date.to_iso8601(date)
  defp format_date(_), do: nil

  defp format_duration(nil), do: nil
  defp format_duration(minutes) when is_integer(minutes) and minutes > 0, do: "PT#{minutes}M"
  defp format_duration(_), do: nil

  defp poster_url(nil, _size), do: nil
  defp poster_url(path, size), do: "#{@tmdb_image_base}/#{size}#{path}"

  defp profile_url(nil, _size), do: nil
  defp profile_url(path, size), do: "#{@tmdb_image_base}/#{size}#{path}"

  defp truncate_bio(nil), do: nil
  defp truncate_bio(""), do: nil

  defp truncate_bio(bio) when is_binary(bio) do
    if String.length(bio) > 500 do
      bio |> String.slice(0, 497) |> Kernel.<>("...")
    else
      bio
    end
  end

  defp person_reference(person) do
    %{
      "@type" => "Person",
      "name" => person.name
    }
    |> maybe_add("url", person_url(person))
  end

  defp person_url(%{slug: slug}) when is_binary(slug), do: "#{@site_url}/people/#{slug}"
  defp person_url(_), do: nil

  # Extract directors from movie credits
  defp get_directors(%{movie_credits: credits}) when is_list(credits) do
    credits
    |> Enum.filter(&(&1.job == "Director" || &1.department == "Directing"))
    |> Enum.map(& &1.person)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(3)
  end

  defp get_directors(_), do: []

  # Extract top-billed actors from movie credits
  defp get_actors(%{movie_credits: credits}) when is_list(credits) do
    credits
    |> Enum.filter(&(&1.department == "Acting" || &1.character != nil))
    |> Enum.sort_by(& &1.order)
    |> Enum.map(& &1.person)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(5)
  end

  defp get_actors(_), do: []

  # Extract genres
  defp get_genres(%{genres: genres}) when is_list(genres) do
    Enum.map(genres, & &1.name)
  end

  defp get_genres(_), do: []

  # Extract rating from external metrics or tmdb_data
  defp get_rating(%{external_metrics: metrics}) when is_list(metrics) do
    case Enum.find(metrics, &(&1.source == "tmdb")) do
      %{vote_average: avg, vote_count: count} when is_number(avg) and is_number(count) ->
        {Float.round(avg, 1), count}

      _ ->
        {0, 0}
    end
  end

  defp get_rating(%{tmdb_data: %{"vote_average" => avg, "vote_count" => count}})
       when is_number(avg) and is_number(count) do
    {Float.round(avg, 1), count}
  end

  defp get_rating(_), do: {0, 0}

  # Extract production companies
  defp get_production_companies(%{production_companies: companies}) when is_list(companies) do
    Enum.map(companies, & &1.name)
  end

  defp get_production_companies(%{tmdb_data: %{"production_companies" => companies}})
       when is_list(companies) do
    Enum.map(companies, & &1["name"])
  end

  defp get_production_companies(_), do: []

  # Build sameAs URLs for movies (IMDb, TMDb links)
  defp build_same_as_urls(movie) do
    urls = []

    urls =
      if movie.imdb_id do
        ["https://www.imdb.com/title/#{movie.imdb_id}/" | urls]
      else
        urls
      end

    urls =
      if movie.tmdb_id do
        ["https://www.themoviedb.org/movie/#{movie.tmdb_id}" | urls]
      else
        urls
      end

    case urls do
      [] -> nil
      urls -> urls
    end
  end

  # Build sameAs URLs for people
  defp build_person_same_as_urls(person) do
    urls = []

    urls =
      if person.imdb_id do
        ["https://www.imdb.com/name/#{person.imdb_id}/" | urls]
      else
        urls
      end

    urls =
      if person.tmdb_id do
        ["https://www.themoviedb.org/person/#{person.tmdb_id}" | urls]
      else
        urls
      end

    case urls do
      [] -> nil
      urls -> urls
    end
  end

  # Get known-for movies for a person
  defp get_known_for_movies(%{credits: credits}) when is_list(credits) do
    credits
    |> Enum.map(& &1.movie)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.take(5)
  end

  defp get_known_for_movies(_), do: []
end
