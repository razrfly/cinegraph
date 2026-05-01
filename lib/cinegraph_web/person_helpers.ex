defmodule CinegraphWeb.PersonHelpers do
  @moduledoc """
  Shared helpers for person-facing routes and presentation.
  """

  alias Cinegraph.Movies.Person

  @doc """
  Returns the canonical URL segment for a person, preferring a non-empty slug.
  """
  def person_slug_or_id(%Person{slug: slug}) when is_binary(slug) and slug != "", do: slug
  def person_slug_or_id(%Person{id: id}), do: to_string(id)
  def person_slug_or_id(%{slug: slug}) when is_binary(slug) and slug != "", do: slug
  def person_slug_or_id(%{id: id}), do: to_string(id)
end
