defmodule CinegraphWeb.SEOHelpers do
  @moduledoc """
  Helper functions for setting SEO-related assigns in LiveViews.

  Usage in a LiveView:
      import CinegraphWeb.SEOHelpers

      socket
      |> assign_movie_seo(movie)

  Or for people:
      socket
      |> assign_person_seo(person)
  """

  import Phoenix.Component, only: [assign: 3]
  alias CinegraphWeb.SEO

  @site_url "https://cinegraph.org"
  @tmdb_image_base "https://image.tmdb.org/t/p"

  @doc """
  Assigns all SEO-related data for a movie page.
  """
  def assign_movie_seo(socket, movie) do
    path = "/movies/#{slug_or_id(movie)}"
    title = movie_title(movie)
    description = movie_description(movie)
    image = movie_image_url(movie)

    socket
    |> assign(:page_title, movie.title)
    |> assign(:meta_title, title)
    |> assign(:meta_description, description)
    |> maybe_assign(:meta_image, image)
    |> assign(:meta_type, "video.movie")
    |> assign(:canonical_url, "#{@site_url}#{path}")
    |> assign(:json_ld, [
      SEO.movie_schema(movie),
      SEO.breadcrumb_schema([
        {"Home", "/"},
        {"Movies", "/movies"},
        {movie.title, path}
      ])
    ])
  end

  @doc """
  Assigns all SEO-related data for a person page.
  """
  def assign_person_seo(socket, person) do
    path = "/people/#{slug_or_id(person)}"
    description = person_description(person)
    image = profile_url(person.profile_path, "w500")

    socket
    |> assign(:page_title, person.name)
    |> assign(:meta_title, person.name)
    |> assign(:meta_description, description)
    |> maybe_assign(:meta_image, image)
    |> assign(:meta_type, "profile")
    |> assign(:canonical_url, "#{@site_url}#{path}")
    |> assign(:json_ld, [
      SEO.person_schema(person),
      SEO.breadcrumb_schema([
        {"Home", "/"},
        {"People", "/people"},
        {person.name, path}
      ])
    ])
  end

  @doc """
  Assigns SEO data for a curated movie list show page.
  """
  def assign_curated_list_seo(socket, list_info, movies) do
    path = "/lists/#{list_info.slug}"
    description = list_info.description || "Browse #{list_info.name} on Cinegraph"
    image = list_image_url(list_info, movies)

    socket
    |> assign(:page_title, list_info.name)
    |> assign(:meta_title, list_info.name)
    |> assign(:meta_description, truncate(description, 160))
    |> maybe_assign(:meta_image, image)
    |> assign(:meta_type, "website")
    |> assign(:canonical_url, "#{@site_url}#{path}")
    |> assign(:json_ld, [
      SEO.item_list_schema(movies, list_info.name),
      SEO.breadcrumb_schema([
        {"Home", "/"},
        {"Lists", "/lists"},
        {list_info.name, path}
      ])
    ])
  end

  @doc """
  Assigns SEO data for an awards/festival show page.
  """
  def assign_awards_seo(socket, organization, filter_mode, movies) do
    title = awards_title(organization, filter_mode)
    description = awards_description(organization, filter_mode)
    path = awards_canonical_path(organization, filter_mode)
    image = awards_image_url(organization, movies)

    socket
    |> assign(:page_title, title)
    |> assign(:meta_title, title)
    |> assign(:meta_description, truncate(description, 160))
    |> maybe_assign(:meta_image, image)
    |> assign(:meta_type, "website")
    |> assign(:canonical_url, "#{@site_url}#{path}")
    |> assign(:json_ld, [
      SEO.item_list_schema(movies, title),
      SEO.breadcrumb_schema([
        {"Home", "/"},
        {"Awards", "/awards"},
        {title, path}
      ])
    ])
  end

  @doc """
  Assigns SEO data for a list page (movie lists, search results, etc.)
  """
  def assign_list_seo(socket, items, title, opts \\ []) do
    description = Keyword.get(opts, :description, "Browse #{title} on Cinegraph")
    path = Keyword.get(opts, :path, "/movies")
    item_type = Keyword.get(opts, :item_type, :movie)

    socket
    |> assign(:page_title, title)
    |> assign(:meta_title, title)
    |> assign(:meta_description, description)
    |> assign(:canonical_url, "#{@site_url}#{path}")
    |> assign(:meta_type, "website")
    |> assign(:json_ld, SEO.item_list_schema(items, title, item_type: item_type))
  end

  @doc """
  Assigns basic SEO data for generic pages.
  """
  def assign_page_seo(socket, title, opts \\ []) do
    description = Keyword.get(opts, :description)
    path = Keyword.get(opts, :path, "/")
    image = Keyword.get(opts, :image)

    socket
    |> assign(:page_title, title)
    |> assign(:meta_title, title)
    |> maybe_assign(:meta_description, description)
    |> assign(:canonical_url, "#{@site_url}#{path}")
    |> maybe_assign(:meta_image, image)
    |> assign(:meta_type, "website")
  end

  # Private helpers

  defp maybe_assign(socket, _key, nil), do: socket
  defp maybe_assign(socket, key, value), do: assign(socket, key, value)

  defp slug_or_id(%{slug: slug}) when is_binary(slug) and slug != "", do: slug
  defp slug_or_id(%{id: id}), do: id

  defp truncate(nil, _length), do: nil
  defp truncate("", _length), do: nil

  defp truncate(text, length) when is_binary(text) do
    if String.length(text) > length do
      text
      |> String.slice(0, length - 3)
      |> String.trim_trailing()
      |> Kernel.<>("...")
    else
      text
    end
  end

  defp movie_title(movie) do
    case movie.release_date do
      %Date{year: year} -> "#{movie.title} (#{year})"
      _ -> movie.title
    end
  end

  defp movie_description(movie) do
    cond do
      present?(movie.overview) ->
        truncate(movie.overview, 160)

      present?(movie.tagline) ->
        truncate(movie.tagline, 160)

      true ->
        "Explore #{movie.title}, its cast, crew, awards, ratings, and film connections on Cinegraph."
    end
  end

  defp movie_image_url(%{backdrop_path: path}) when is_binary(path) and path != "",
    do: poster_url(path, "w1280")

  defp movie_image_url(%{poster_path: path}) when is_binary(path) and path != "",
    do: poster_url(path, "w780")

  defp movie_image_url(_movie), do: nil

  defp poster_url(nil, _size), do: nil
  defp poster_url("", _size), do: nil
  defp poster_url(path, size), do: "#{@tmdb_image_base}/#{size}#{path}"

  defp profile_url(nil, _size), do: nil
  defp profile_url("", _size), do: nil
  defp profile_url(path, size), do: "#{@tmdb_image_base}/#{size}#{path}"

  defp person_description(person) do
    cond do
      person.biography && String.length(person.biography) > 0 ->
        truncate(person.biography, 160)

      person.known_for_department ->
        "#{person.name} is known for #{person.known_for_department}. Explore their filmography on Cinegraph."

      true ->
        "Explore #{person.name}'s filmography, collaborations, and career on Cinegraph."
    end
  end

  defp list_image_url(list_info, movies) do
    first_present([
      Map.get(list_info, :hero_image_url),
      Map.get(list_info, :cover_image_url),
      first_movie_poster(movies)
    ])
  end

  defp awards_image_url(organization, movies) do
    first_present([
      Map.get(organization, :hero_image_url),
      Map.get(organization, :logo_url),
      first_movie_poster(movies)
    ])
  end

  defp first_movie_poster([%{poster_path: poster_path} | _])
       when is_binary(poster_path) and poster_path != "" do
    poster_url(poster_path, "w780")
  end

  defp first_movie_poster(_movies), do: nil

  defp first_present(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        if String.trim(value) == "", do: nil, else: value

      value ->
        value
    end)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp awards_title(org, :winners), do: "#{org.name} Winners"
  defp awards_title(org, :nominees), do: "#{org.name} Nominees"
  defp awards_title(org, _), do: org.name

  defp awards_description(org, :winners) do
    "Browse all #{org.name} award winners. Discover acclaimed films honored by #{org.name}."
  end

  defp awards_description(org, :nominees) do
    "Browse #{org.name} nominees. Explore films nominated for #{org.name} awards."
  end

  defp awards_description(org, _) do
    "Explore #{org.name} films, winners, and nominees. Discover award-winning cinema on Cinegraph."
  end

  defp awards_canonical_path(org, :winners), do: "/awards/#{slug_or_id(org)}/winners"
  defp awards_canonical_path(org, :nominees), do: "/awards/#{slug_or_id(org)}/nominees"
  defp awards_canonical_path(org, _), do: "/awards/#{slug_or_id(org)}"
end
