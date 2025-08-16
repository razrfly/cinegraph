# Test script to see full OMDb response
IO.puts("Loading environment...")
System.put_env("OMDB_API_KEY", "e291bc36")

alias Cinegraph.Services.OMDb

IO.puts("\nFetching OMDb data for The Shawshank Redemption...")
case OMDb.Client.get_movie_by_imdb_id("tt0111161", tomatoes: true) do
  {:ok, data} ->
    IO.puts("\n=== FULL OMDB RESPONSE ===")
    IO.inspect(data, limit: :infinity, pretty: true)
    
    IO.puts("\n=== AWARDS DATA ===")
    IO.puts("Awards: #{data["Awards"]}")
    
    IO.puts("\n=== ADDITIONAL FIELDS WE'RE NOT STORING ===")
    fields_not_stored = [
      {"Title", data["Title"]},
      {"Year", data["Year"]},
      {"Rated", data["Rated"]},
      {"Released", data["Released"]},
      {"Genre", data["Genre"]},
      {"Director", data["Director"]},
      {"Writer", data["Writer"]},
      {"Actors", data["Actors"]},
      {"Plot", data["Plot"]},
      {"Language", data["Language"]},
      {"Country", data["Country"]},
      {"Poster", data["Poster"]},
      {"Metascore", data["Metascore"]},
      {"imdbRating", data["imdbRating"]},
      {"imdbVotes", data["imdbVotes"]},
      {"Type", data["Type"]},
      {"DVD", data["DVD"]},
      {"Production", data["Production"]},
      {"Website", data["Website"]}
    ]
    
    Enum.each(fields_not_stored, fn {field, value} ->
      if value && value != "N/A" do
        IO.puts("#{field}: #{value}")
      end
    end)
    
  {:error, reason} ->
    IO.puts("Error: #{reason}")
end