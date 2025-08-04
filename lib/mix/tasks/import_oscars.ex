defmodule Mix.Tasks.ImportOscars do
  use Mix.Task
  
  @shortdoc "Import Oscar ceremony data and create/update movies"
  
  @moduledoc """
  Import Oscar ceremony data for specified years.
  
  ## Usage
  
      mix import_oscars --year 2024
      mix import_oscars --years 2020-2024
      mix import_oscars --all
      
  ## Options
  
    * `--year` - Import a single year
    * `--years` - Import a range of years (format: START-END)
    * `--all` - Import all available years (2016-2024)
    * `--skip-enrichment` - Skip OMDb enrichment queue
    * `--dry-run` - Show what would be imported without making changes
    
  ## Examples
  
      # Import 2024 Oscar data
      mix import_oscars --year 2024
      
      # Import multiple years
      mix import_oscars --years 2020-2024
      
      # Import all available years
      mix import_oscars --all
      
      # Dry run to see what would be imported
      mix import_oscars --year 2024 --dry-run
      
  """
  
  def run(args) do
    # Start the application
    Mix.Task.run("app.start")
    
    # Parse arguments
    {opts, _, _} = OptionParser.parse(args,
      strict: [
        year: :integer,
        years: :string,
        all: :boolean,
        skip_enrichment: :boolean,
        dry_run: :boolean
      ]
    )
    
    # Prepare options for import
    import_options = [
      create_movies: !opts[:dry_run],
      queue_enrichment: !opts[:skip_enrichment] && !opts[:dry_run]
    ]
    
    cond do
      opts[:year] ->
        import_single_year(opts[:year], import_options, opts[:dry_run])
        
      opts[:years] ->
        import_year_range(opts[:years], import_options, opts[:dry_run])
        
      opts[:all] ->
        import_all_years(import_options, opts[:dry_run])
        
      true ->
        Mix.shell().error("Please specify --year, --years, or --all")
        Mix.shell().info("\nUsage: mix import_oscars --year 2024")
        Mix.shell().info("       mix import_oscars --years 2020-2024")
        Mix.shell().info("       mix import_oscars --all")
    end
  end
  
  defp import_single_year(year, options, dry_run) do
    Mix.shell().info("#{if dry_run, do: "[DRY RUN] ", else: ""}Importing Oscar data for #{year}...")
    
    if dry_run do
      show_year_preview(year)
    else
      case Cinegraph.Cultural.import_oscar_year(year, options) do
        {:ok, result} ->
          show_import_results(year, result)
          
        {:error, reason} ->
          Mix.shell().error("Failed to import year #{year}: #{inspect(reason)}")
      end
    end
  end
  
  defp import_year_range(range_str, options, dry_run) do
    case parse_year_range(range_str) do
      {:ok, start_year, end_year} ->
        Mix.shell().info("#{if dry_run, do: "[DRY RUN] ", else: ""}Importing Oscar data for years #{start_year}-#{end_year}...")
        
        if dry_run do
          Enum.each(start_year..end_year, &show_year_preview/1)
        else
          case Cinegraph.Cultural.import_oscar_years(start_year..end_year, options) do
            {:ok, %{job_count: count, status: :queued}} ->
              Mix.shell().info("\n✅ Queued #{count} import jobs for years #{start_year}-#{end_year}")
              Mix.shell().info("Monitor progress at: http://localhost:4001/dev/oban")
              Mix.shell().info("\nTo check status in IEx:")
              Mix.shell().info("  Cinegraph.Cultural.get_oscar_import_status()")
              
            %{} = results ->
              # Sequential processing results
              Enum.each(results, fn {year, result} ->
                case result do
                  {:ok, data} -> show_import_results(year, data)
                  {:error, reason} -> Mix.shell().error("Year #{year} failed: #{inspect(reason)}")
                end
              end)
              
              show_summary(results)
              
            {:error, reason} ->
              Mix.shell().error("Failed to queue jobs: #{inspect(reason)}")
          end
        end
        
      :error ->
        Mix.shell().error("Invalid year range format. Use: START-END (e.g., 2020-2024)")
    end
  end
  
  defp import_all_years(options, dry_run) do
    Mix.shell().info("#{if dry_run, do: "[DRY RUN] ", else: ""}Importing all available Oscar years (2016-2024)...")
    
    if dry_run do
      Enum.each(2016..2024, &show_year_preview/1)
    else
      case Cinegraph.Cultural.import_all_oscar_years(options) do
        {:ok, %{job_count: count, status: :queued}} ->
          Mix.shell().info("\n✅ Queued #{count} import jobs for all Oscar years")
          Mix.shell().info("Monitor progress at: http://localhost:4001/dev/oban")
          Mix.shell().info("\nTo check status in IEx:")
          Mix.shell().info("  Cinegraph.Cultural.get_oscar_import_status()")
          
        %{} = results ->
          # Sequential processing results
          Enum.each(results, fn {year, result} ->
            case result do
              {:ok, data} -> show_import_results(year, data)
              {:error, reason} -> Mix.shell().error("Year #{year} failed: #{inspect(reason)}")
            end
          end)
          
          show_summary(results)
          
        {:error, reason} ->
          Mix.shell().error("Failed to queue jobs: #{inspect(reason)}")
      end
    end
  end
  
  defp parse_year_range(range_str) do
    case String.split(range_str, "-") do
      [start_str, end_str] ->
        with {start_year, ""} <- Integer.parse(start_str),
             {end_year, ""} <- Integer.parse(end_str),
             true <- start_year <= end_year do
          {:ok, start_year, end_year}
        else
          _ -> :error
        end
        
      _ -> :error
    end
  end
  
  defp show_year_preview(year) do
    ceremony_number = year - 1927
    Mix.shell().info("  • Year #{year} (#{Number.Human.number_to_ordinal(ceremony_number)} Academy Awards)")
    Mix.shell().info("    URL: https://www.oscars.org/oscars/ceremonies/#{year}")
  end
  
  defp show_import_results(year, result) do
    Mix.shell().info("\n✅ Year #{year} imported successfully:")
    Mix.shell().info("  • Movies created: #{result.movies_created}")
    Mix.shell().info("  • Movies updated: #{result.movies_updated}")
    Mix.shell().info("  • Movies skipped: #{result.movies_skipped}")
    Mix.shell().info("  • Total nominees: #{result.total_nominees}")
  end
  
  defp show_summary(results) do
    total_created = results |> Enum.map(fn {_, r} -> 
      case r do
        {:ok, data} -> data.movies_created
        _ -> 0
      end
    end) |> Enum.sum()
    
    total_updated = results |> Enum.map(fn {_, r} -> 
      case r do
        {:ok, data} -> data.movies_updated
        _ -> 0
      end
    end) |> Enum.sum()
    
    successful = Enum.count(results, fn {_, r} -> match?({:ok, _}, r) end)
    failed = Enum.count(results, fn {_, r} -> match?({:error, _}, r) end)
    
    Mix.shell().info("\n📊 Import Summary:")
    Mix.shell().info("  • Years processed: #{map_size(results)}")
    Mix.shell().info("  • Successful: #{successful}")
    Mix.shell().info("  • Failed: #{failed}")
    Mix.shell().info("  • Total movies created: #{total_created}")
    Mix.shell().info("  • Total movies updated: #{total_updated}")
  end
  
end