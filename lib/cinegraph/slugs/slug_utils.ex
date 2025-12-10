defmodule Cinegraph.Slugs.SlugUtils do
  @moduledoc """
  Shared slug generation utilities with proper Unicode transliteration.

  Uses the Slugify library to properly handle non-Latin characters:
  - Chinese: "你好" → "nihao"
  - Cyrillic: "Москва" → "moskva"
  - Japanese: "東京" → "dong-jing" (kanji to pinyin)
  - Arabic: "مرحبا" → "mrhba"
  - Accented: "café" → "cafe"

  This module provides the core slugification logic used by both
  MovieSlug and PersonSlug to ensure consistent slug generation.
  """

  @doc """
  Slugifies a string with proper Unicode transliteration.

  Uses the Slug library which handles:
  - Unicode normalization
  - Transliteration of non-Latin scripts
  - Lowercase conversion
  - Whitespace to hyphen conversion
  - Multiple hyphen consolidation

  ## Examples

      iex> SlugUtils.slugify("The Matrix")
      "the-matrix"

      iex> SlugUtils.slugify("七人の侍")
      "qi-ren-no-shi"

      iex> SlugUtils.slugify("Москва слезам не верит")
      "moskva-slezam-ne-verit"

      iex> SlugUtils.slugify(nil)
      "untitled"

  """
  @spec slugify(String.t() | nil) :: String.t()
  def slugify(nil), do: "untitled"
  def slugify(""), do: "untitled"

  def slugify(string) when is_binary(string) do
    result = Slug.slugify(string, separator: "-")

    case result do
      nil -> "untitled"
      "" -> "untitled"
      slug -> slug
    end
  end

  @doc """
  Creates a base slug with year suffix.

  ## Examples

      iex> SlugUtils.create_slug_with_year("The Matrix", 1999)
      "the-matrix-1999"

      iex> SlugUtils.create_slug_with_year("七人の侍", 1954)
      "qi-ren-no-shi-1954"

      iex> SlugUtils.create_slug_with_year("Untitled", nil)
      "untitled-unknown"

  """
  @spec create_slug_with_year(String.t() | nil, integer() | nil) :: String.t()
  def create_slug_with_year(title, year) do
    base = slugify(title)
    year_str = if year, do: "#{year}", else: "unknown"
    "#{base}-#{year_str}"
  end

  @doc """
  Extracts a slugified last name from a full name.

  Useful for director disambiguation in movie slugs.

  ## Examples

      iex> SlugUtils.slugify_last_name("Christopher Nolan")
      "nolan"

      iex> SlugUtils.slugify_last_name("David Cronenberg")
      "cronenberg"

      iex> SlugUtils.slugify_last_name("黒澤明")
      "ming"

  """
  @spec slugify_last_name(String.t() | nil) :: String.t() | nil
  def slugify_last_name(nil), do: nil
  def slugify_last_name(""), do: nil

  def slugify_last_name(name) when is_binary(name) do
    name
    |> String.split(" ")
    |> List.last()
    |> slugify()
  end

  @doc """
  Extracts a country code for use in slug disambiguation.

  Normalizes country codes to lowercase.

  ## Examples

      iex> SlugUtils.normalize_country("US")
      "us"

      iex> SlugUtils.normalize_country("JP")
      "jp"

  """
  @spec normalize_country(String.t() | nil) :: String.t() | nil
  def normalize_country(nil), do: nil
  def normalize_country(""), do: nil
  def normalize_country(country), do: String.downcase(country)

  @doc """
  Extracts year from a Date or returns nil.

  ## Examples

      iex> SlugUtils.extract_year(~D[1999-03-31])
      1999

      iex> SlugUtils.extract_year(nil)
      nil

  """
  @spec extract_year(Date.t() | nil) :: integer() | nil
  def extract_year(%Date{year: year}), do: year
  def extract_year(_), do: nil

  @doc """
  Creates a person slug with birth year for disambiguation.

  ## Examples

      iex> SlugUtils.create_person_slug_with_year("Tom Hanks", 1956)
      "tom-hanks-1956"

      iex> SlugUtils.create_person_slug_with_year("成龍", 1954)
      "cheng-long-1954"

  """
  @spec create_person_slug_with_year(String.t() | nil, integer() | nil) :: String.t()
  def create_person_slug_with_year(name, year) do
    base = slugify(name)
    "#{base}-#{year}"
  end

  @doc """
  Creates a person slug with country for disambiguation.

  ## Examples

      iex> SlugUtils.create_person_slug_with_country("Michael Jackson", "US")
      "michael-jackson-us"

  """
  @spec create_person_slug_with_country(String.t() | nil, String.t() | nil) :: String.t()
  def create_person_slug_with_country(name, country) do
    base = slugify(name)
    country_code = normalize_country(country)
    "#{base}-#{country_code}"
  end

  @doc """
  Creates a fallback slug using tmdb_id.

  This is the last resort when all other disambiguation methods fail.

  ## Examples

      iex> SlugUtils.create_fallback_slug("tmdb", 550)
      "tmdb-550"

  """
  @spec create_fallback_slug(String.t(), integer()) :: String.t()
  def create_fallback_slug(prefix, id) do
    "#{prefix}-#{id}"
  end
end
