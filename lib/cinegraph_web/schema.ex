defmodule CinegraphWeb.Schema do
  use Absinthe.Schema

  import_types(CinegraphWeb.Schema.MovieTypes)
  import_types(CinegraphWeb.Schema.PersonTypes)

  alias CinegraphWeb.Resolvers.{MovieResolver, PersonResolver}
  alias CinegraphWeb.Middleware.ApiAuth

  scalar :json, name: "JSON" do
    description("Arbitrary JSON value (map, list, or scalar)")
    serialize(fn v -> v end)

    parse(fn
      %Absinthe.Blueprint.Input.String{value: value} -> Jason.decode(value)
      %Absinthe.Blueprint.Input.Null{} -> {:ok, nil}
      _ -> :error
    end)
  end

  def context(ctx) do
    loader =
      Dataloader.new()
      |> Dataloader.add_source(:db, Dataloader.Ecto.new(Cinegraph.Repo))

    Map.put(ctx, :loader, loader)
  end

  def plugins do
    [Absinthe.Middleware.Dataloader] ++ Absinthe.Plugin.defaults()
  end

  query do
    @desc "Look up a single movie by TMDb ID, IMDb ID, or slug"
    field :movie, :movie do
      arg(:tmdb_id, :integer)
      arg(:imdb_id, :string)
      arg(:slug, :string)

      middleware(ApiAuth)
      resolve(&MovieResolver.movie/3)
    end

    @desc "Look up multiple movies by a list of TMDb IDs"
    field :movies, list_of(:movie) do
      arg(:tmdb_ids, non_null(list_of(non_null(:integer))))

      middleware(ApiAuth)
      resolve(&MovieResolver.movies/3)
    end

    @desc "Search movies by title with optional year filter"
    field :search_movies, list_of(:movie) do
      arg(:query, non_null(:string))
      arg(:year, :integer)
      arg(:limit, :integer)

      middleware(ApiAuth)
      resolve(&MovieResolver.search_movies/3)
    end

    @desc "Look up a single person by TMDb ID or slug"
    field :person, :person do
      arg(:tmdb_id, :integer)
      arg(:slug, :string)

      middleware(ApiAuth)
      resolve(&PersonResolver.person/3)
    end
  end
end
