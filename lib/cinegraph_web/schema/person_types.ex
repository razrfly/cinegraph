defmodule CinegraphWeb.Schema.PersonTypes do
  use Absinthe.Schema.Notation

  @desc "A person (actor, director, crew member)"
  object :person do
    field :tmdb_id, :integer
    field :name, :string
    field :slug, :string
    field :profile_path, :string
    field :biography, :string
    field :known_for_department, :string
    field :birthday, :string
    field :deathday, :string
  end
end
