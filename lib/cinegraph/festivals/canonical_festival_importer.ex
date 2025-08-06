defmodule Cinegraph.Festivals.CanonicalFestivalImporter do
  @moduledoc """
  Imports festival awards from canonical sources (Cannes, Venice, Berlin) into the unified festival structure.
  """
  
  alias Cinegraph.{Repo, Festivals}
  alias Cinegraph.Movies.Movie
  import Ecto.Query
  require Logger
  
  @festival_mapping %{
    "cannes_winners" => %{
      organization: "Cannes",
      default_prize: "Palme d'Or",
      categories: %{
        "Palme d'Or" => {"film", false},
        "Grand Prix" => {"film", false},
        "Best Director" => {"person", true},
        "Best Actor" => {"person", true},
        "Best Actress" => {"person", true},
        "Best Screenplay" => {"person", true},
        "Jury Prize" => {"film", false},
        "Camera d'Or" => {"film", false}
      }
    },
    "venice_golden_lion" => %{
      organization: "Venice",
      default_prize: "Golden Lion",
      categories: %{
        "Golden Lion" => {"film", false},
        "Silver Lion" => {"film", false},
        "Best Director" => {"person", true},
        "Best Actor" => {"person", true},
        "Best Actress" => {"person", true},
        "Best Screenplay" => {"person", true},
        "Special Jury Prize" => {"film", false}
      }
    },
    "berlin_golden_bear" => %{
      organization: "Berlinale",
      default_prize: "Golden Bear",
      categories: %{
        "Golden Bear" => {"film", false},
        "Silver Bear" => {"film", false},
        "Best Director" => {"person", true},
        "Best Actor" => {"person", true},
        "Best Actress" => {"person", true},
        "Best Screenplay" => {"person", true},
        "Alfred Bauer Prize" => {"film", false}
      }
    }
  }
  
  @doc """
  Process all movies with canonical sources and create festival nominations.
  """
  def import_all_canonical_awards do
    Logger.info("Importing canonical festival awards into unified structure...")
    
    results = Enum.map(@festival_mapping, fn {source_key, _config} ->
      import_festival_awards(source_key)
    end)
    
    summarize_results(results)
  end
  
  @doc """
  Import awards for a specific festival from canonical sources.
  """
  def import_festival_awards(source_key) do
    config = @festival_mapping[source_key]
    
    unless config do
      Logger.error("Unknown festival source: #{source_key}")
      {:error, :unknown_source}
    else
    
    # Get the festival organization
    org = Festivals.get_organization_by_abbreviation(config[:organization])
    
    unless org do
      Logger.error("Festival organization not found: #{config[:organization]}")
      {:error, :organization_not_found}
    else
    
    # Get all movies with this canonical source
    movies = from(m in Movie,
      where: fragment("? \\? ?", m.canonical_sources, ^source_key),
      select: m
    )
    |> Repo.all()
    
    Logger.info("Processing #{length(movies)} movies for #{org.name}")
    
    # Process each movie
    results = Enum.map(movies, fn movie ->
      process_movie_awards(movie, source_key, org, config)
    end)
    
    %{
      festival: org.name,
      movies_processed: length(movies),
      nominations_created: Enum.count(results, & &1 == :ok),
      errors: Enum.count(results, & elem(&1, 0) == :error)
    }
    end
    end
  end
  
  defp process_movie_awards(movie, source_key, organization, config) do
    canonical_data = movie.canonical_sources[source_key]
    
    # Extract awards from canonical data
    extracted_awards = canonical_data["extracted_awards"] || []
    year = canonical_data["scraped_year"] || extract_year_from_award_text(canonical_data["award_text"])
    
    if Enum.empty?(extracted_awards) do
      # No structured awards - try to create from award_text
      if canonical_data["award_text"] do
        create_nomination_from_text(movie, organization, year, canonical_data["award_text"], config)
      else
        Logger.warning("No award data for #{movie.title} in #{source_key}")
        {:error, :no_awards}
      end
    else
      # Create nominations for each extracted award
      Enum.map(extracted_awards, fn award ->
        create_nomination_from_award(movie, organization, award, config)
      end)
    end
  end
  
  defp create_nomination_from_award(movie, organization, award, config) do
    award_name = award["award_name"]
    award_year = award["award_year"] || Date.utc_today().year
    award_category = award["award_category"]
    
    # Determine the category
    category_name = determine_category_name(award_name, award_category, config)
    {category_type, tracks_person} = config[:categories][category_name] || {"special", false}
    
    # Create or get ceremony
    {:ok, ceremony} = Festivals.find_or_create_ceremony(
      organization.id,
      String.to_integer(to_string(award_year)),
      %{name: "#{organization.name} #{award_year}"}
    )
    
    # Create or get category
    {:ok, category} = Festivals.find_or_create_category(
      organization.id,
      category_name,
      %{
        category_type: category_type,
        tracks_person: tracks_person
      }
    )
    
    # Create nomination
    attrs = %{
      ceremony_id: ceremony.id,
      category_id: category.id,
      movie_id: movie.id,
      won: true, # Canonical lists typically only include winners
      prize_name: award_name,
      details: %{
        "source" => "canonical_import",
        "raw_award_text" => award["raw_text"]
      }
    }
    
    case Festivals.create_nomination(attrs) do
      {:ok, _nomination} ->
        Logger.info("Created #{organization.name} nomination for #{movie.title}: #{award_name}")
        :ok
      {:error, changeset} ->
        Logger.error("Failed to create nomination: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end
  
  defp create_nomination_from_text(movie, organization, year, award_text, config) do
    # Fallback for unstructured award text
    year = year || Date.utc_today().year
    
    # Create or get ceremony
    {:ok, ceremony} = Festivals.find_or_create_ceremony(
      organization.id,
      year,
      %{name: "#{organization.name} #{year}"}
    )
    
    # Use default category
    {:ok, category} = Festivals.find_or_create_category(
      organization.id,
      config[:default_prize],
      %{
        category_type: "film",
        tracks_person: false
      }
    )
    
    # Create nomination
    attrs = %{
      ceremony_id: ceremony.id,
      category_id: category.id,
      movie_id: movie.id,
      won: true,
      prize_name: config[:default_prize],
      details: %{
        "source" => "canonical_import",
        "raw_award_text" => award_text
      }
    }
    
    case Festivals.create_nomination(attrs) do
      {:ok, _nomination} ->
        Logger.info("Created #{organization.name} nomination for #{movie.title}")
        :ok
      {:error, changeset} ->
        Logger.error("Failed to create nomination: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end
  
  defp determine_category_name(award_name, award_category, config) do
    # Try to match award name to known categories
    normalized_name = String.downcase(award_name)
    
    found_category = Enum.find(config[:categories], fn {category, _} ->
      String.contains?(normalized_name, String.downcase(category))
    end)
    
    case found_category do
      {category_name, _} -> category_name
      nil -> 
        # Use award category if provided, otherwise use award name
        award_category || award_name
    end
  end
  
  defp extract_year_from_award_text(nil), do: nil
  defp extract_year_from_award_text(text) do
    case Regex.run(~r/\b(19\d{2}|20\d{2})\b/, text) do
      [_, year_str] -> String.to_integer(year_str)
      _ -> nil
    end
  end
  
  defp summarize_results(results) do
    %{
      festivals_processed: length(results),
      total_movies: Enum.sum(Enum.map(results, & &1.movies_processed)),
      total_nominations: Enum.sum(Enum.map(results, & &1.nominations_created)),
      total_errors: Enum.sum(Enum.map(results, & &1.errors)),
      details: results
    }
  end
  
  @doc """
  Import a single movie's canonical awards into the festival structure.
  """
  def import_movie_canonical_awards(movie_id) do
    movie = Repo.get!(Movie, movie_id)
    
    results = Enum.map(@festival_mapping, fn {source_key, config} ->
      if Map.has_key?(movie.canonical_sources || %{}, source_key) do
        org = Festivals.get_organization_by_abbreviation(config[:organization])
        process_movie_awards(movie, source_key, org, config)
      else
        nil
      end
    end)
    |> Enum.filter(& &1)
    
    %{
      movie: movie.title,
      results: results
    }
  end
end