defmodule CinegraphWeb.Schema.SearchTypes do
  @moduledoc """
  GraphQL object types for the unified `globalSearch` query.

  These describe the shaped maps returned by `Cinegraph.Search.global/2` —
  small projections of the underlying domain types, optimized for typeahead
  consumption rather than full record fetches.
  """

  use Absinthe.Schema.Notation

  @desc "A film hit returned by globalSearch"
  object :search_film do
    field :id, :id
    field :tmdb_id, :integer
    field :title, :string
    field :slug, :string
    field :year, :integer, description: "Release year derived from release_date"

    field :poster_path, :string,
      description: "TMDb path; build URL with image.tmdb.org/t/p/{size}{path}"

    field :director, :string, description: "Primary director, if available"
  end

  @desc "A person hit returned by globalSearch"
  object :search_person do
    field :id, :id
    field :tmdb_id, :integer
    field :name, :string
    field :slug, :string

    field :profile_path, :string,
      description: "TMDb path; build URL with image.tmdb.org/t/p/{size}{path}"

    field :known_for_department, :string
  end

  @desc "A canonical movie list returned by globalSearch"
  object :search_list do
    field :id, :id
    field :name, :string
    field :slug, :string
    field :short_name, :string
    field :icon, :string
  end

  @desc "A production company returned by globalSearch"
  object :search_company do
    field :id, :id
    field :tmdb_id, :integer
    field :name, :string

    field :logo_path, :string,
      description: "TMDb path; build URL with image.tmdb.org/t/p/{size}{path}"

    field :origin_country, :string
  end

  @desc "Grouped results from a globalSearch query"
  object :search_results do
    field :films, list_of(:search_film)
    field :people, list_of(:search_person)
    field :lists, list_of(:search_list)
    field :companies, list_of(:search_company)
    field :total_count, :integer
  end
end
