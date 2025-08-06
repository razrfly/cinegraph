defmodule Cinegraph.Services.Wikidata do
  @moduledoc """
  Wikidata integration for fetching award and cultural list data.
  Uses SPARQL queries to get structured data about movie awards and recognitions.
  """

  @sparql_endpoint "https://query.wikidata.org/sparql"

  @doc """
  Fetches award data for a movie using its IMDb ID.
  Returns a list of awards with categories and results (winner/nominee).
  """
  def fetch_movie_awards(imdb_id) when is_binary(imdb_id) do
    query = """
    SELECT ?award ?awardLabel ?category ?categoryLabel ?year ?result
    WHERE {
      ?movie wdt:P345 "#{imdb_id}" .
      
      # Awards received
      OPTIONAL {
        ?movie p:P166 ?awardStatement .
        ?awardStatement ps:P166 ?award .
        OPTIONAL { ?awardStatement pq:P31 ?category }
        OPTIONAL { ?awardStatement pq:P585 ?date }
        OPTIONAL { ?awardStatement pq:P1552 ?hasQuality }
        BIND(YEAR(?date) AS ?year)
        BIND(IF(BOUND(?hasQuality), "winner", "nominee") AS ?result)
      }
      
      # Nominated for
      OPTIONAL {
        ?movie p:P1411 ?nominationStatement .
        ?nominationStatement ps:P1411 ?award .
        OPTIONAL { ?nominationStatement pq:P31 ?category }
        OPTIONAL { ?nominationStatement pq:P585 ?date }
        BIND(YEAR(?date) AS ?year)
        BIND("nominee" AS ?result)
      }
      
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en" }
    }
    """

    case execute_sparql_query(query) do
      {:ok, results} ->
        awards = parse_award_results(results)
        {:ok, awards}

      error ->
        error
    end
  end

  @doc """
  Fetches cultural list memberships for a movie.
  """
  def fetch_movie_lists(imdb_id) when is_binary(imdb_id) do
    query = """
    SELECT ?list ?listLabel ?rank ?year
    WHERE {
      ?movie wdt:P345 "#{imdb_id}" .
      
      # Part of lists
      ?list p:P527 ?hasPart .
      ?hasPart ps:P527 ?movie .
      OPTIONAL { ?hasPart pq:P1545 ?rank }
      OPTIONAL { ?hasPart pq:P585 ?date }
      BIND(YEAR(?date) AS ?year)
      
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en" }
    }
    """

    case execute_sparql_query(query) do
      {:ok, results} ->
        lists = parse_list_results(results)
        {:ok, lists}

      error ->
        error
    end
  end

  @doc """
  Fetches basic movie data from Wikidata including awards count.
  """
  def fetch_movie_data(imdb_id) when is_binary(imdb_id) do
    query = """
    SELECT ?movie ?movieLabel ?publicationDate 
           (COUNT(DISTINCT ?award) as ?awardCount)
           (COUNT(DISTINCT ?nomination) as ?nominationCount)
    WHERE {
      ?movie wdt:P345 "#{imdb_id}" .
      OPTIONAL { ?movie wdt:P577 ?publicationDate }
      OPTIONAL { ?movie wdt:P166 ?award }
      OPTIONAL { ?movie wdt:P1411 ?nomination }
      
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en" }
    }
    GROUP BY ?movie ?movieLabel ?publicationDate
    """

    execute_sparql_query(query)
  end

  # Private functions

  defp execute_sparql_query(query) do
    headers = [
      {"Accept", "application/sparql-results+json"},
      {"User-Agent", "Cinegraph/1.0 (https://github.com/razrfly/cinegraph)"}
    ]

    params = URI.encode_query(%{query: query})
    url = "#{@sparql_endpoint}?#{params}"

    case HTTPoison.get(url, headers, timeout: 30_000, recv_timeout: 30_000) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"results" => %{"bindings" => bindings}}} ->
            {:ok, bindings}

          {:error, _} ->
            {:error, :invalid_json}
        end

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp parse_award_results(bindings) do
    bindings
    |> Enum.map(fn binding ->
      %{
        award_name: get_in(binding, ["awardLabel", "value"]),
        award_id: extract_wikidata_id(get_in(binding, ["award", "value"])),
        category: get_in(binding, ["categoryLabel", "value"]),
        year: parse_integer(get_in(binding, ["year", "value"])),
        result: get_in(binding, ["result", "value"]) || "nominee"
      }
    end)
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.year || 9999, &1.award_name})
  end

  defp parse_list_results(bindings) do
    bindings
    |> Enum.map(fn binding ->
      %{
        list_name: get_in(binding, ["listLabel", "value"]),
        list_id: extract_wikidata_id(get_in(binding, ["list", "value"])),
        rank: parse_integer(get_in(binding, ["rank", "value"])),
        year: parse_integer(get_in(binding, ["year", "value"]))
      }
    end)
    |> Enum.uniq()
  end

  defp extract_wikidata_id(nil), do: nil

  defp extract_wikidata_id(url) when is_binary(url) do
    case Regex.run(~r/Q\d+$/, url) do
      [id] -> id
      _ -> nil
    end
  end

  defp parse_integer(nil), do: nil

  defp parse_integer(str) when is_binary(str) do
    case Integer.parse(str) do
      {num, _} -> num
      _ -> nil
    end
  end
end
