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
    field :ivory_tower, :float, description: "Critics score (Metacritic, RT Tomatometer) — 0-10"
    field :festival_recognition, :float, description: "Festival & award recognition — 0-10"
    field :cultural_impact, :float, description: "Canonical sources & cultural reach — 0-10"
    field :people_quality, :float, description: "Cast & crew quality — 0-10"
    field :financial_performance, :float, description: "Box office performance — 0-10"
    field :overall, :float, description: "Weighted overall score — 0-10"
    field :confidence, :float, description: "Data confidence — 0-1"
    field :disparity_score, :float, description: "Mob vs ivory_tower gap"

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
  end
end
