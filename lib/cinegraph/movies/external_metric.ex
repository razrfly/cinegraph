defmodule Cinegraph.Movies.ExternalMetric do
  use Ecto.Schema
  import Ecto.Changeset

  schema "external_metrics" do
    belongs_to :movie, Cinegraph.Movies.Movie
    
    field :source, :string
    field :metric_type, :string
    field :value, :float
    field :text_value, :string
    field :metadata, :map, default: %{}
    field :fetched_at, :utc_datetime
    field :valid_until, :utc_datetime

    timestamps()
  end

  @required_fields [:movie_id, :source, :metric_type, :fetched_at]
  @optional_fields [:value, :text_value, :metadata, :valid_until]

  @doc false
  def changeset(metric, attrs) do
    metric
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:source, ["tmdb", "omdb", "imdb", "rotten_tomatoes", "metacritic", "the_numbers"])
    |> validate_metric_type()
    |> foreign_key_constraint(:movie_id)
    |> unique_constraint([:movie_id, :source, :metric_type],
      name: :external_metrics_movie_source_type_index,
      message: "metric already exists for this movie, source, and type"
    )
  end

  defp validate_metric_type(changeset) do
    case get_field(changeset, :metric_type) do
      nil -> changeset
      type -> 
        if type in valid_metric_types() do
          changeset
        else
          add_error(changeset, :metric_type, "invalid metric type")
        end
    end
  end

  defp valid_metric_types do
    [
      # Ratings
      "rating_average",
      "rating_votes",
      "tomatometer",
      "audience_score",
      "metascore",
      
      # Financial
      "budget",
      "revenue_worldwide",
      "revenue_domestic",
      "revenue_international",
      "revenue_opening_weekend",
      
      # Popularity
      "popularity_score",
      "trending_rank",
      "popularity_rank",
      
      # Awards
      "awards_summary",
      "oscar_wins",
      "oscar_nominations",
      "total_awards",
      "total_nominations"
    ]
  end

  @doc """
  Create metrics from TMDb data
  """
  def from_tmdb(movie_id, tmdb_data) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    metrics = []

    # Ratings
    metrics = if tmdb_data["vote_average"] && tmdb_data["vote_average"] > 0 do
      [%{
        movie_id: movie_id,
        source: "tmdb",
        metric_type: "rating_average",
        value: tmdb_data["vote_average"],
        metadata: %{"scale" => "1-10"},
        fetched_at: now
      } | metrics]
    else
      metrics
    end

    metrics = if tmdb_data["vote_count"] && tmdb_data["vote_count"] > 0 do
      [%{
        movie_id: movie_id,
        source: "tmdb",
        metric_type: "rating_votes",
        value: tmdb_data["vote_count"],
        fetched_at: now
      } | metrics]
    else
      metrics
    end

    # Popularity
    metrics = if tmdb_data["popularity"] do
      [%{
        movie_id: movie_id,
        source: "tmdb",
        metric_type: "popularity_score",
        value: tmdb_data["popularity"],
        metadata: %{"algorithm_version" => "v3"},
        fetched_at: now
      } | metrics]
    else
      metrics
    end

    # Financial
    metrics = if tmdb_data["budget"] && tmdb_data["budget"] > 0 do
      [%{
        movie_id: movie_id,
        source: "tmdb",
        metric_type: "budget",
        value: tmdb_data["budget"],
        metadata: %{"currency" => "USD"},
        fetched_at: now
      } | metrics]
    else
      metrics
    end

    metrics = if tmdb_data["revenue"] && tmdb_data["revenue"] > 0 do
      [%{
        movie_id: movie_id,
        source: "tmdb",
        metric_type: "revenue_worldwide",
        value: tmdb_data["revenue"],
        metadata: %{"currency" => "USD"},
        fetched_at: now
      } | metrics]
    else
      metrics
    end

    metrics
  end

  @doc """
  Create metrics from OMDb data
  """
  def from_omdb(movie_id, omdb_data) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    metrics = []

    # IMDb Rating
    metrics = if omdb_data["imdbRating"] && omdb_data["imdbRating"] != "N/A" do
      rating = String.to_float(omdb_data["imdbRating"])
      [%{
        movie_id: movie_id,
        source: "imdb",
        metric_type: "rating_average",
        value: rating,
        metadata: %{"scale" => "1-10"},
        fetched_at: now
      } | metrics]
    else
      metrics
    end

    # IMDb Votes
    metrics = if omdb_data["imdbVotes"] && omdb_data["imdbVotes"] != "N/A" do
      votes = omdb_data["imdbVotes"] 
        |> String.replace(",", "")
        |> String.to_integer()
      [%{
        movie_id: movie_id,
        source: "imdb",
        metric_type: "rating_votes",
        value: votes,
        fetched_at: now
      } | metrics]
    else
      metrics
    end

    # Metascore
    metrics = if omdb_data["Metascore"] && omdb_data["Metascore"] != "N/A" do
      score = String.to_integer(omdb_data["Metascore"])
      [%{
        movie_id: movie_id,
        source: "metacritic",
        metric_type: "metascore",
        value: score,
        metadata: %{"scale" => "0-100", "type" => "critics"},
        fetched_at: now
      } | metrics]
    else
      metrics
    end

    # Box Office
    metrics = if omdb_data["BoxOffice"] && omdb_data["BoxOffice"] != "N/A" do
      revenue = omdb_data["BoxOffice"]
        |> String.replace(~r/[^0-9]/, "")
        |> String.to_integer()
      [%{
        movie_id: movie_id,
        source: "omdb",
        metric_type: "revenue_domestic",
        value: revenue,
        metadata: %{"currency" => "USD", "territory" => "USA/Canada"},
        fetched_at: now
      } | metrics]
    else
      metrics
    end

    # Awards
    metrics = if omdb_data["Awards"] && omdb_data["Awards"] != "N/A" do
      awards_text = omdb_data["Awards"]
      metadata = parse_awards_text(awards_text)
      
      [%{
        movie_id: movie_id,
        source: "omdb",
        metric_type: "awards_summary",
        text_value: awards_text,
        metadata: metadata,
        fetched_at: now
      } | metrics]
    else
      metrics
    end

    # Rotten Tomatoes from Ratings array
    if omdb_data["Ratings"] && is_list(omdb_data["Ratings"]) do
      Enum.reduce(omdb_data["Ratings"], metrics, fn rating, acc ->
        case rating["Source"] do
          "Rotten Tomatoes" ->
            value = rating["Value"] 
              |> String.replace("%", "")
              |> String.to_integer()
            [%{
              movie_id: movie_id,
              source: "rotten_tomatoes",
              metric_type: "tomatometer",
              value: value,
              metadata: %{"scale" => "0-100", "type" => "critics"},
              fetched_at: now
            } | acc]
          _ -> acc
        end
      end)
    else
      metrics
    end
  end

  defp parse_awards_text(text) do
    metadata = %{}
    
    # Parse Oscar wins
    metadata = case Regex.run(~r/Won (\d+) Oscar/, text) do
      [_, count] -> Map.put(metadata, "oscar_wins", String.to_integer(count))
      _ -> metadata
    end

    # Parse total wins
    metadata = case Regex.run(~r/(\d+) wins?/, text) do
      [_, count] -> Map.put(metadata, "total_wins", String.to_integer(count))
      _ -> metadata
    end

    # Parse total nominations  
    metadata = case Regex.run(~r/(\d+) nominations?/, text) do
      [_, count] -> Map.put(metadata, "total_nominations", String.to_integer(count))
      _ -> metadata
    end

    metadata
  end
end