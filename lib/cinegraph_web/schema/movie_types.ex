defmodule CinegraphWeb.Schema.MovieTypes do
  use Absinthe.Schema.Notation

  import Absinthe.Resolution.Helpers, only: [dataloader: 1]

  alias CinegraphWeb.Resolvers.MovieResolver

  @desc "Aggregated ratings from external sources"
  object :movie_ratings do
    field :tmdb, :float, description: "TMDb vote average (0-10)"
    field :tmdb_votes, :integer, description: "Number of TMDb votes"
    field :imdb, :float, description: "IMDb rating (0-10)"
    field :imdb_votes, :integer, description: "Number of IMDb votes"
    field :rotten_tomatoes, :integer, description: "Rotten Tomatoes Tomatometer (0-100)"
    field :metacritic, :integer, description: "Metacritic Metascore (0-100)"
  end

  @desc "Awards data from OMDb and festival nominations"
  object :movie_awards do
    field :summary, :string, description: "Human-readable awards summary from OMDb"
    field :oscar_wins, :integer, description: "Number of Academy Award wins"
    field :total_wins, :integer, description: "Total award wins across all ceremonies"
    field :total_nominations, :integer, description: "Total nominations across all ceremonies"
  end

  @desc "Cached 6-lens scores for a movie"
  object :lens_scores do
    field :mob, :float, description: "Audience score (IMDb, TMDb, RT Audience) — 0-10"
    field :critics, :float, description: "Critics score (Metacritic, RT Tomatometer) — 0-10"
    field :festival_recognition, :float, description: "Festival & award recognition — 0-10"

    field :industry_recognition, :float,
      description: "Deprecated. Use festival_recognition instead.",
      deprecate: "Use festival_recognition instead"

    field :time_machine, :float, description: "Canonical sources & cultural reach — 0-10"
    field :auteurs, :float, description: "Cast & crew quality — 0-10"
    field :box_office, :float, description: "Box office performance — 0-10"
    field :overall, :float, description: "Weighted overall score — 0-10"
    field :confidence, :float, description: "Data confidence — 0-1"

    field :display_score, :float,
      description: "Public CineGraph score, null when evidence is insufficient"

    field :sort_score, :float, description: "Evidence-adjusted CineGraph sort score"
    field :scoreability_state, :string, description: "scoreable | limited | insufficient_evidence"
    field :score_confidence_label, :string, description: "high | medium | low | insufficient"
    field :present_lens_count, :integer, description: "Number of available evidence lenses"
    field :missing_lens_count, :integer, description: "Number of unavailable evidence lenses"
    field :present_lens_labels, list_of(:string), description: "Available evidence lens keys"
    field :missing_lens_labels, list_of(:string), description: "Unavailable evidence lens keys"

    field :score_hidden_reason, :string,
      description: "none | no_score_cache | not_enough_evidence"

    field :disparity_score, :float, description: "Mob vs critics gap"

    field :disparity_category, :string,
      description: "critics_darling | peoples_champion | perfect_harmony | polarizer"

    field :unpredictability_score, :float, description: "Score volatility — 0-10"
  end

  @desc "A credit linking a person to a movie"
  object :credit do
    field :credit_type, :string
    field :character, :string
    field :cast_order, :integer
    field :department, :string
    field :job, :string

    field :person, :person do
      resolve(dataloader(:db))
    end
  end

  @desc "A movie video (trailer, teaser, etc.)"
  object :movie_video do
    field :name, :string
    field :key, :string
    field :site, :string
    field :type, :string
    field :official, :boolean
  end

  @desc "A region option where watch availability can be displayed"
  object :availability_region_option do
    field :region, :string
    field :label, :string
  end

  @desc "A streaming/rental provider catalog entry"
  object :watch_provider do
    field :source, :string
    field :source_provider_id, :string
    field :tmdb_provider_id, :integer
    field :name, :string
    field :logo_path, :string
    field :logo_url, :string
    field :display_priorities, :json
  end

  @desc "A movie/provider availability row for a monetization type"
  object :movie_watch_provider_availability do
    field :monetization_type, :string
    field :display_priority, :integer
    field :tmdb_link, :string
    field :fetched_at, :string
    field :stale_after, :string
    field :provider, :watch_provider
  end

  @desc "Watch availability providers grouped by monetization type"
  object :movie_availability_group do
    field :monetization_type, :string
    field :label, :string
    field :providers, list_of(:movie_watch_provider_availability)
  end

  @desc "Current watch availability for a movie in a selected region"
  object :movie_availability do
    field :region, :string
    field :region_label, :string
    field :status, :string
    field :tmdb_link, :string
    field :fetched_at, :string
    field :stale_after, :string
    field :is_stale, :boolean
    field :refresh_queued, :boolean
    field :groups, list_of(:movie_availability_group)
    field :available_regions, list_of(:availability_region_option)
  end

  @desc "A movie with all associated data"
  object :movie do
    field :tmdb_id, :integer
    field :imdb_id, :string
    field :title, :string
    field :slug, :string
    field :overview, :string
    field :runtime, :integer
    field :release_date, :string
    field :poster_path, :string
    field :backdrop_path, :string
    field :canonical_sources, :json

    field :cinegraph_url, :string do
      resolve(fn movie, _, _ ->
        base =
          :cinegraph
          |> Application.get_env(:cinegraph_base_url, "")
          |> String.trim_trailing("/")

        path =
          if movie.slug && movie.slug != "",
            do: "/movies/#{movie.slug}",
            else: "/movies/tmdb/#{movie.tmdb_id}"

        {:ok, "#{base}#{path}"}
      end)
    end

    field :is_currently_in_theaters, :boolean do
      resolve(fn movie, _, _ ->
        {:ok, Cinegraph.Movies.currently_in_theaters?(movie)}
      end)
    end

    field :wombie_url, :string,
      description: "Showtimes link on wombie.com — nil when movie is not currently in theaters" do
      resolve(fn movie, _, _ ->
        if Cinegraph.Movies.currently_in_theaters?(movie) do
          {:ok, CinegraphWeb.Helpers.WombieLinks.showtimes_url(movie, "graphql")}
        else
          {:ok, nil}
        end
      end)
    end

    field :now_playing_regions, list_of(:string) do
      resolve(fn movie, _, _ ->
        {:ok, Cinegraph.Movies.active_now_playing_regions(movie)}
      end)
    end

    field :ratings, :movie_ratings do
      resolve(&MovieResolver.ratings/3)
    end

    field :awards, :movie_awards do
      resolve(&MovieResolver.awards/3)
    end

    field :lens_scores, :lens_scores do
      resolve(&MovieResolver.lens_scores/3)
    end

    field :cast, list_of(:credit) do
      resolve(&MovieResolver.cast/3)
    end

    field :crew, list_of(:credit) do
      resolve(&MovieResolver.crew/3)
    end

    field :videos, list_of(:movie_video) do
      resolve(&MovieResolver.videos/3)
    end

    field :availability, :movie_availability do
      arg(:region, :string)
      resolve(&MovieResolver.availability/3)
    end
  end
end
