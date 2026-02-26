defmodule CinegraphWeb.Resolvers.PersonResolver do
  @moduledoc """
  GraphQL resolvers for person queries.
  """

  alias Cinegraph.Repo
  alias Cinegraph.Movies.Person

  def person(_, args, _) do
    cond do
      tmdb_id = args[:tmdb_id] ->
        fetch_person(:tmdb_id, tmdb_id)

      slug = args[:slug] ->
        fetch_person(:slug, slug)

      true ->
        {:error, "Must provide tmdb_id or slug"}
    end
  end

  defp fetch_person(field, value) do
    case Repo.get_by(Person, [{field, value}]) do
      nil -> {:error, "Person not found"}
      person -> {:ok, person}
    end
  end
end
