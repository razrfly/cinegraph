#!/usr/bin/env elixir

# Test script for extended TMDB endpoints
# Run with: mix run test_tmdb_extended_endpoints.exs

alias Cinegraph.Services.TMDb.Extended

defmodule TMDbExtendedTest do
  @test_movie_id 550  # Fight Club
  @test_person_id 287  # Brad Pitt
  
  def run do
    IO.puts("\n🎬 Testing Extended TMDB Endpoints")
    IO.puts("=" <> String.duplicate("=", 60))
    
    # Test each critical endpoint
    test_watch_providers()
    test_reviews()
    test_trending()
    test_now_playing()
    test_upcoming()
    test_certifications()
    test_enhanced_discover()
    test_person_endpoints()
    test_search_endpoints()
    test_configuration()
    
    IO.puts("\n✅ All tests completed!")
  end
  
  defp test_watch_providers do
    IO.puts("\n📺 Testing Watch Providers...")
    
    case Extended.get_movie_watch_providers(@test_movie_id) do
      {:ok, data} ->
        IO.puts("✅ Watch providers fetched successfully")
        
        # Show sample data for US
        if us_data = get_in(data, ["results", "US"]) do
          IO.puts("   US Providers:")
          
          Enum.each(["flatrate", "rent", "buy"], fn type ->
            if providers = Map.get(us_data, type) do
              IO.puts("   - #{String.capitalize(type)}: #{length(providers)} providers")
              
              # Show first provider as example
              if first = List.first(providers) do
                IO.puts("     Example: #{first["provider_name"]} (ID: #{first["provider_id"]})")
              end
            end
          end)
        end
        
        # Count total regions
        regions = Map.keys(data["results"] || %{})
        IO.puts("   Total regions with data: #{length(regions)}")
        
      {:error, reason} ->
        IO.puts("❌ Failed to fetch watch providers: #{inspect(reason)}")
    end
  end
  
  defp test_reviews do
    IO.puts("\n💬 Testing Reviews...")
    
    case Extended.get_movie_reviews(@test_movie_id) do
      {:ok, data} ->
        IO.puts("✅ Reviews fetched successfully")
        IO.puts("   Total reviews: #{data["total_results"]}")
        
        # Show first review as example
        if review = List.first(data["results"] || []) do
          IO.puts("   Sample review by: #{review["author"]}")
          IO.puts("   Rating: #{get_in(review, ["author_details", "rating"]) || "N/A"}")
          IO.puts("   Content preview: #{String.slice(review["content"] || "", 0..100)}...")
        end
        
      {:error, reason} ->
        IO.puts("❌ Failed to fetch reviews: #{inspect(reason)}")
    end
  end
  
  defp test_trending do
    IO.puts("\n📈 Testing Trending...")
    
    # Test movie trending
    IO.puts("   Movies (Daily):")
    case Extended.get_trending_movies("day") do
      {:ok, data} ->
        IO.puts("   ✅ Daily trending movies: #{length(data["results"] || [])} results")
        
        # Show top 3
        data["results"]
        |> Enum.take(3)
        |> Enum.with_index(1)
        |> Enum.each(fn {movie, rank} ->
          IO.puts("      #{rank}. #{movie["title"]} (#{movie["release_date"]})")
        end)
        
      {:error, reason} ->
        IO.puts("   ❌ Failed: #{inspect(reason)}")
    end
    
    # Test person trending
    IO.puts("   People (Daily):")
    case Extended.get_trending_people("day") do
      {:ok, data} ->
        IO.puts("   ✅ Daily trending people: #{length(data["results"] || [])} results")
        
        # Show top 3
        data["results"]
        |> Enum.take(3)
        |> Enum.with_index(1)
        |> Enum.each(fn {person, rank} ->
          IO.puts("      #{rank}. #{person["name"]} (#{person["known_for_department"]})")
        end)
        
      {:error, reason} ->
        IO.puts("   ❌ Failed: #{inspect(reason)}")
    end
  end
  
  defp test_now_playing do
    IO.puts("\n🎭 Testing Now Playing...")
    
    case Extended.get_now_playing_movies(region: "US") do
      {:ok, data} ->
        IO.puts("✅ Now playing movies fetched")
        IO.puts("   Total in US theaters: #{data["total_results"]}")
        IO.puts("   Date range: #{get_in(data, ["dates", "minimum"])} to #{get_in(data, ["dates", "maximum"])}")
        
        # Show top 3
        data["results"]
        |> Enum.take(3)
        |> Enum.each(fn movie ->
          IO.puts("   - #{movie["title"]} (Released: #{movie["release_date"]})")
        end)
        
      {:error, reason} ->
        IO.puts("❌ Failed to fetch now playing: #{inspect(reason)}")
    end
  end
  
  defp test_upcoming do
    IO.puts("\n🔮 Testing Upcoming...")
    
    case Extended.get_upcoming_movies(region: "US") do
      {:ok, data} ->
        IO.puts("✅ Upcoming movies fetched")
        IO.puts("   Total upcoming in US: #{data["total_results"]}")
        
        # Show next 3 releases
        data["results"]
        |> Enum.take(3)
        |> Enum.each(fn movie ->
          IO.puts("   - #{movie["title"]} (Releases: #{movie["release_date"]})")
        end)
        
      {:error, reason} ->
        IO.puts("❌ Failed to fetch upcoming: #{inspect(reason)}")
    end
  end
  
  defp test_certifications do
    IO.puts("\n🔞 Testing Certifications...")
    
    case Extended.get_movie_certifications() do
      {:ok, data} ->
        IO.puts("✅ Certifications fetched")
        
        # Show US certifications
        if us_certs = data["certifications"]["US"] do
          IO.puts("   US Certifications:")
          Enum.each(us_certs, fn cert ->
            IO.puts("   - #{cert["certification"]}: #{String.slice(cert["meaning"], 0..50)}...")
          end)
        end
        
        # Count total countries
        countries = Map.keys(data["certifications"] || %{})
        IO.puts("   Total countries with certifications: #{length(countries)}")
        
      {:error, reason} ->
        IO.puts("❌ Failed to fetch certifications: #{inspect(reason)}")
    end
  end
  
  defp test_enhanced_discover do
    IO.puts("\n🔍 Testing Enhanced Discover...")
    
    # Test with multiple filters
    filters = [
      with_original_language: "es",
      vote_average_gte: 7.0,
      primary_release_date_gte: "2023-01-01",
      sort_by: "popularity.desc",
      page: 1
    ]
    
    IO.puts("   Testing with filters: Spanish language, 7+ rating, 2023+ release")
    
    case Extended.discover_movies_enhanced(filters) do
      {:ok, data} ->
        IO.puts("✅ Enhanced discover successful")
        IO.puts("   Found #{data["total_results"]} movies matching criteria")
        
        # Show top 3 results
        data["results"]
        |> Enum.take(3)
        |> Enum.each(fn movie ->
          IO.puts("   - #{movie["title"]} (#{movie["original_language"]}, ⭐ #{movie["vote_average"]})")
        end)
        
      {:error, reason} ->
        IO.puts("❌ Failed enhanced discover: #{inspect(reason)}")
    end
  end
  
  defp test_person_endpoints do
    IO.puts("\n👥 Testing Person Endpoints...")
    
    # Test popular people
    case Extended.get_popular_people(page: 1) do
      {:ok, data} ->
        IO.puts("✅ Popular people fetched")
        
        # Show top 3
        data["results"]
        |> Enum.take(3)
        |> Enum.with_index(1)
        |> Enum.each(fn {person, rank} ->
          known_for = person["known_for"] |> Enum.map(&(&1["title"] || &1["name"])) |> Enum.join(", ")
          IO.puts("   #{rank}. #{person["name"]} - Known for: #{String.slice(known_for, 0..50)}...")
        end)
        
      {:error, reason} ->
        IO.puts("❌ Failed to fetch popular people: #{inspect(reason)}")
    end
  end
  
  defp test_search_endpoints do
    IO.puts("\n🔎 Testing Search Endpoints...")
    
    # Test person search
    IO.puts("   Person Search (Brad Pitt):")
    case Extended.search_people("Brad Pitt") do
      {:ok, data} ->
        if person = List.first(data["results"] || []) do
          IO.puts("   ✅ Found: #{person["name"]} (ID: #{person["id"]})")
        end
      {:error, reason} ->
        IO.puts("   ❌ Failed: #{inspect(reason)}")
    end
    
    # Test multi search
    IO.puts("   Multi Search (Inception):")
    case Extended.search_multi("Inception") do
      {:ok, data} ->
        results_by_type = Enum.group_by(data["results"] || [], & &1["media_type"])
        IO.puts("   ✅ Found: #{map_size(results_by_type)} media types")
        
        Enum.each(results_by_type, fn {type, items} ->
          IO.puts("      - #{type}: #{length(items)} results")
        end)
        
      {:error, reason} ->
        IO.puts("   ❌ Failed: #{inspect(reason)}")
    end
  end
  
  defp test_configuration do
    IO.puts("\n⚙️  Testing Configuration...")
    
    # Test main configuration
    case Extended.get_configuration() do
      {:ok, data} ->
        IO.puts("✅ Configuration fetched")
        IO.puts("   Image base URL: #{get_in(data, ["images", "secure_base_url"])}")
        IO.puts("   Backdrop sizes: #{length(get_in(data, ["images", "backdrop_sizes"]) || [])}")
        IO.puts("   Poster sizes: #{length(get_in(data, ["images", "poster_sizes"]) || [])}")
      {:error, reason} ->
        IO.puts("❌ Failed: #{inspect(reason)}")
    end
    
    # Test genres
    IO.puts("   Genres:")
    case Extended.get_movie_genres() do
      {:ok, data} ->
        genres = data["genres"] || []
        IO.puts("   ✅ Found #{length(genres)} genres")
        
        # Show first 5
        genres
        |> Enum.take(5)
        |> Enum.each(fn genre ->
          IO.puts("      - #{genre["name"]} (ID: #{genre["id"]})")
        end)
        
      {:error, reason} ->
        IO.puts("   ❌ Failed: #{inspect(reason)}")
    end
  end
end

# Run the tests
TMDbExtendedTest.run()