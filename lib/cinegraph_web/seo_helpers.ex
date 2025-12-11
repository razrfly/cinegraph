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

  @site_url "https://cinegraph.io"
  @tmdb_image_base "https://image.tmdb.org/t/p"

  @doc """
  Assigns all SEO-related data for a movie page.
  """
  def assign_movie_seo(socket, movie) do
    socket
    |> assign(:page_title, movie.title)
    |> assign(:meta_description, truncate(movie.overview, 160))
    |> assign(:canonical_url, "#{@site_url}/movies/#{movie.slug}")
    |> assign(:og_title, movie.title)
    |> assign(:og_description, truncate(movie.overview, 200))
    |> assign(:og_image, poster_url(movie.poster_path, "w780"))
    |> assign(:og_type, "video.movie")
    |> assign(:og_url, "#{@site_url}/movies/#{movie.slug}")
    |> assign(:json_ld, SEO.movie_schema(movie))
  end

  @doc """
  Assigns all SEO-related data for a person page.
  """
  def assign_person_seo(socket, person) do
    socket
    |> assign(:page_title, person.name)
    |> assign(:meta_description, person_description(person))
    |> assign(:canonical_url, "#{@site_url}/people/#{person.slug}")
    |> assign(:og_title, person.name)
    |> assign(:og_description, person_description(person))
    |> assign(:og_image, profile_url(person.profile_path, "w500"))
    |> assign(:og_type, "profile")
    |> assign(:og_url, "#{@site_url}/people/#{person.slug}")
    |> assign(:json_ld, SEO.person_schema(person))
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
    |> assign(:meta_description, description)
    |> assign(:canonical_url, "#{@site_url}#{path}")
    |> assign(:og_title, title)
    |> assign(:og_description, description)
    |> assign(:og_type, "website")
    |> assign(:og_url, "#{@site_url}#{path}")
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
    |> maybe_assign(:meta_description, description)
    |> assign(:canonical_url, "#{@site_url}#{path}")
    |> assign(:og_title, title)
    |> maybe_assign(:og_description, description)
    |> maybe_assign(:og_image, image)
    |> assign(:og_type, "website")
    |> assign(:og_url, "#{@site_url}#{path}")
  end

  # Private helpers

  defp maybe_assign(socket, _key, nil), do: socket
  defp maybe_assign(socket, key, value), do: assign(socket, key, value)

  defp truncate(nil, _length), do: nil

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

  defp poster_url(nil, _size), do: nil
  defp poster_url(path, size), do: "#{@tmdb_image_base}/#{size}#{path}"

  defp profile_url(nil, _size), do: nil
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
end
