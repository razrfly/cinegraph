defmodule CinegraphWeb.Schema do
  use Absinthe.Schema

  import_types(CinegraphWeb.Schema.MovieTypes)
  import_types(CinegraphWeb.Schema.PersonTypes)
  import_types(CinegraphWeb.Schema.SearchTypes)

  alias CinegraphWeb.Resolvers.{MovieResolver, PersonResolver, SearchResolver}
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
      |> Dataloader.add_source(
        :availability,
        Dataloader.KV.new(&MovieResolver.load_availability/2, async?: false)
      )

    Map.put(ctx, :loader, loader)
  end

  def plugins do
    [Absinthe.Middleware.Dataloader] ++ Absinthe.Plugin.defaults()
  end

  enum :movie_discovery_match do
    value(:all, description: "A movie must contain every requested ID in this filter group")

    value(:any,
      description: "A movie must contain at least one requested ID in this filter group"
    )
  end

  query do
    @desc "Search TMDb movie keywords with eligible fully imported movie counts"
    field :search_movie_keywords,
          non_null(list_of(non_null(:movie_metadata_vocabulary_term))) do
      arg(:query, non_null(:string))
      arg(:limit, :integer, default_value: 10)

      complexity(fn args, child_complexity ->
        limit = args |> Map.get(:limit, 10) |> max(1) |> min(50)
        5 + limit * max(child_complexity, 1)
      end)

      middleware(ApiAuth)
      resolve(&MovieResolver.search_movie_keywords/3)
    end

    @desc "List the stable TMDb movie genre vocabulary with eligible movie counts"
    field :movie_genres,
          non_null(list_of(non_null(:movie_metadata_vocabulary_term))) do
      complexity(fn _, child_complexity -> 5 + 50 * max(child_complexity, 1) end)

      middleware(ApiAuth)
      resolve(&MovieResolver.movie_genres/3)
    end

    @desc "Discover fully imported movies through stored TMDb keywords and genres"
    field :discover_movies, :movie_discovery_connection do
      arg(:keyword_tmdb_ids, list_of(non_null(:integer)))
      arg(:genre_tmdb_ids, list_of(non_null(:integer)))
      arg(:keyword_match, :movie_discovery_match, default_value: :all)
      arg(:genre_match, :movie_discovery_match, default_value: :all)
      arg(:first, :integer, default_value: 12)
      arg(:after, :string)

      complexity(fn args, child_complexity ->
        first = args |> Map.get(:first, 12) |> max(1) |> min(50)
        15 + first * max(child_complexity, 1)
      end)

      middleware(ApiAuth)
      resolve(&MovieResolver.discover_movies/3)
    end

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

    @desc "Unified typeahead across films, people, lists, and production companies"
    field :global_search, :search_results do
      arg(:q, non_null(:string))
      arg(:limit, :integer, default_value: 5)

      middleware(ApiAuth)
      resolve(&SearchResolver.global_search/3)
    end

    @desc "Movies currently playing in theaters, sourced from TMDB and updated every 6 hours"
    field :now_playing_movies, list_of(:movie) do
      arg(:limit, :integer, default_value: 100)
      arg(:recency_days, :integer)
      arg(:region, :string)

      middleware(ApiAuth)
      resolve(&MovieResolver.now_playing_movies/3)
    end
  end
end
