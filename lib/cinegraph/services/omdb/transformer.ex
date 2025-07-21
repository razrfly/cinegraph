defmodule Cinegraph.Services.OMDb.Transformer do
  @moduledoc """
  Transforms OMDb API responses into our database structures.
  """
  
  alias Cinegraph.Repo
  alias Cinegraph.ExternalSources.Source
  
  require Logger
  
  @doc """
  Get or create the OMDb source record
  """
  def get_or_create_source! do
    case Repo.get_by(Source, name: "OMDb") do
      nil ->
        %Source{}
        |> Source.changeset(%{
          name: "OMDb",
          source_type: "api",
          base_url: "http://www.omdbapi.com",
          api_version: "1",
          weight_factor: 1.0,
          active: true,
          config: %{
            "tier" => "free",
            "includes" => ["imdb", "rotten_tomatoes", "metacritic"]
          }
        })
        |> Repo.insert!()
      
      source -> source
    end
  end
  
  @doc """
  Transform OMDb response into rating records
  """
  def transform_to_ratings(omdb_data, movie_id, source_id) do
    # Parse Ratings array
    ratings = parse_ratings_array(omdb_data["Ratings"] || [], movie_id, source_id)
    
    # Add IMDb votes as a rating
    if imdb_votes = parse_imdb_votes(omdb_data["imdbVotes"]) do
      ratings = ratings ++ [
        %{
          movie_id: movie_id,
          source_id: source_id,
          rating_type: "popularity",
          value: imdb_votes,
          scale_min: 0.0,
          scale_max: 10_000_000.0,
          metadata: %{
            "source_name" => "IMDb",
            "metric" => "vote_count",
            "raw_value" => omdb_data["imdbVotes"]
          },
          fetched_at: DateTime.utc_now()
        }
      ]
    end
    
    # Add Box Office if available
    if box_office = parse_box_office(omdb_data["BoxOffice"]) do
      ratings = ratings ++ [
        %{
          movie_id: movie_id,
          source_id: source_id,
          rating_type: "engagement",
          value: box_office,
          scale_min: 0.0,
          scale_max: 1_000_000_000.0,
          metadata: %{
            "source_name" => "Box Office",
            "currency" => "USD",
            "market" => "domestic",
            "raw_value" => omdb_data["BoxOffice"]
          },
          fetched_at: DateTime.utc_now()
        }
      ]
    end
    
    # Add Rotten Tomatoes extended data if available
    ratings = ratings ++ parse_tomato_data(omdb_data, movie_id, source_id)
    
    ratings
  end
  
  defp parse_ratings_array(ratings_array, movie_id, source_id) do
    Enum.flat_map(ratings_array, fn rating ->
      case parse_single_rating(rating, movie_id, source_id) do
        nil -> []
        parsed -> [parsed]
      end
    end)
  end
  
  defp parse_single_rating(%{"Source" => source, "Value" => value}, movie_id, source_id) do
    case source do
      "Internet Movie Database" ->
        if parsed_value = parse_imdb_rating(value) do
          %{
            movie_id: movie_id,
            source_id: source_id,
            rating_type: "user",
            value: parsed_value,
            scale_min: 0.0,
            scale_max: 10.0,
            metadata: %{
              "source_name" => "IMDb",
              "raw_value" => value
            },
            fetched_at: DateTime.utc_now()
          }
        end
        
      "Rotten Tomatoes" ->
        if parsed_value = parse_percentage(value) do
          %{
            movie_id: movie_id,
            source_id: source_id,
            rating_type: "critic",
            value: parsed_value,
            scale_min: 0.0,
            scale_max: 100.0,
            metadata: %{
              "source_name" => "Rotten Tomatoes",
              "raw_value" => value
            },
            fetched_at: DateTime.utc_now()
          }
        end
        
      "Metacritic" ->
        if parsed_value = parse_metacritic(value) do
          %{
            movie_id: movie_id,
            source_id: source_id,
            rating_type: "critic",
            value: parsed_value,
            scale_min: 0.0,
            scale_max: 100.0,
            metadata: %{
              "source_name" => "Metacritic",
              "raw_value" => value
            },
            fetched_at: DateTime.utc_now()
          }
        end
        
      _ ->
        Logger.warning("Unknown rating source: #{source}")
        nil
    end
  end
  
  defp parse_tomato_data(data, movie_id, source_id) do
    critic_ratings = 
      if tomato_meter = safe_parse_float(data["tomatoMeter"]) do
        metadata = %{
          "source_name" => "Rotten Tomatoes Critics",
          "consensus" => data["tomatoConsensus"],
          "fresh_count" => safe_parse_integer(data["tomatoFresh"]),
          "rotten_count" => safe_parse_integer(data["tomatoRotten"]),
          "total_reviews" => safe_parse_integer(data["tomatoReviews"]),
          "image" => data["tomatoImage"],
          "rating" => safe_parse_float(data["tomatoRating"])
        } |> Enum.filter(fn {_, v} -> v != nil end) |> Map.new()
        
        [%{
          movie_id: movie_id,
          source_id: source_id,
          rating_type: "critic",
          value: tomato_meter,
          scale_min: 0.0,
          scale_max: 100.0,
          sample_size: metadata["total_reviews"],
          metadata: metadata,
          fetched_at: DateTime.utc_now()
        }]
      else
        []
      end
    
    audience_ratings = 
      if user_meter = safe_parse_float(data["tomatoUserMeter"]) do
        metadata = %{
          "source_name" => "Rotten Tomatoes Audience",
          "rating" => safe_parse_float(data["tomatoUserRating"]),
          "review_count" => safe_parse_integer(data["tomatoUserReviews"])
        } |> Enum.filter(fn {_, v} -> v != nil end) |> Map.new()
        
        [%{
          movie_id: movie_id,
          source_id: source_id,
          rating_type: "user",
          value: user_meter,
          scale_min: 0.0,
          scale_max: 100.0,
          sample_size: metadata["review_count"],
          metadata: metadata,
          fetched_at: DateTime.utc_now()
        }]
      else
        []
      end
    
    critic_ratings ++ audience_ratings
  end
  
  @doc """
  Parse awards text into structured data (enhanced version)
  """
  def parse_awards(awards_text) when awards_text in [nil, "N/A"], do: nil
  def parse_awards(awards_text) do
    %{
      raw_text: awards_text,
      has_oscars: String.contains?(awards_text, ["Oscar", "Academy Award"]),
      oscar_wins: extract_oscar_wins(awards_text),
      oscar_nominations: extract_oscar_nominations(awards_text),
      total_wins: extract_total_wins(awards_text),
      total_nominations: extract_total_nominations(awards_text),
      has_golden_globe: String.contains?(awards_text, "Golden Globe"),
      has_bafta: String.contains?(awards_text, "BAFTA"),
      has_emmy: String.contains?(awards_text, "Emmy"),
      has_sag: String.contains?(awards_text, ["SAG", "Screen Actors Guild"]),
      parsed_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
  
  # Parsing helpers
  defp parse_imdb_rating(value) do
    case String.split(value, "/") do
      [rating, "10"] -> safe_parse_float(rating)
      _ -> nil
    end
  end
  
  defp parse_percentage(value) do
    value
    |> String.replace("%", "")
    |> safe_parse_float()
  end
  
  defp parse_metacritic(value) do
    case String.split(value, "/") do
      [score, "100"] -> safe_parse_float(score)
      _ -> nil
    end
  end
  
  defp parse_imdb_votes(nil), do: nil
  defp parse_imdb_votes("N/A"), do: nil
  defp parse_imdb_votes(votes_string) do
    votes_string
    |> String.replace(",", "")
    |> safe_parse_integer()
  end
  
  defp parse_box_office(nil), do: nil
  defp parse_box_office("N/A"), do: nil
  defp parse_box_office(box_office_string) do
    box_office_string
    |> String.replace("$", "")
    |> String.replace(",", "")
    |> safe_parse_float()
  end
  
  defp safe_parse_float(nil), do: nil
  defp safe_parse_float("N/A"), do: nil
  defp safe_parse_float(string) when is_binary(string) do
    case Float.parse(string) do
      {float, _} -> float
      :error -> nil
    end
  end
  defp safe_parse_float(num) when is_number(num), do: num / 1
  
  defp safe_parse_integer(nil), do: nil
  defp safe_parse_integer("N/A"), do: nil
  defp safe_parse_integer(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, _} -> int
      :error -> nil
    end
  end
  defp safe_parse_integer(num) when is_integer(num), do: num
  
  defp extract_oscar_wins(text) do
    case Regex.run(~r/Won (\d+) Oscar/i, text) do
      [_, count] -> String.to_integer(count)
      _ -> 0
    end
  end
  
  defp extract_oscar_nominations(text) do
    case Regex.run(~r/Nominated for (\d+) Oscar/i, text) do
      [_, count] -> String.to_integer(count)
      _ -> 0
    end
  end
  
  defp extract_total_wins(text) do
    case Regex.run(~r/(\d+) wins?/i, text) do
      [_, count] -> String.to_integer(count)
      _ -> 0
    end
  end
  
  defp extract_total_nominations(text) do
    case Regex.run(~r/(\d+) nominations?/i, text) do
      [_, count] -> String.to_integer(count)
      _ -> 0
    end
  end
end