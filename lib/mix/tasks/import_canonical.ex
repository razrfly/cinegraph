defmodule Mix.Tasks.ImportCanonical do
  use Mix.Task

  @shortdoc "Import canonical movie lists and create/update movies"

  @moduledoc """
  Import canonical movie lists from IMDb user lists.

  ## Usage

      mix import_canonical --list 1001_movies
      mix import_canonical --list-id ls024863935 --source-key 1001_movies --name "1001 Movies You Must See Before You Die"
      mix import_canonical --all
      
  ## Options

    * `--list` - Import a predefined list (1001_movies)
    * `--list-id` - IMDb list ID (e.g., ls024863935)
    * `--source-key` - Internal key for the canonical source
    * `--name` - Human-readable name for the list
    * `--all` - Import all predefined canonical lists
    * `--skip-creation` - Skip creating new movies
    * `--dry-run` - Show what would be imported without making changes
    
  ## Examples

      # Import 1001 Movies list
      mix import_canonical --list 1001_movies
      
      # Import a custom list
      mix import_canonical --list-id ls123456789 --source-key sight_sound --name "Sight & Sound Greatest Films"
      
      # Import all predefined lists
      mix import_canonical --all
      
      # Dry run to see what would be imported
      mix import_canonical --list 1001_movies --dry-run
      
  """

  # Get lists from database (single source of truth)
  defp predefined_lists do
    Cinegraph.Movies.MovieLists.all_as_config()
  end

  def run(args) do
    # Start the application
    Mix.Task.run("app.start")

    # Parse arguments
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          list: :string,
          list_id: :string,
          source_key: :string,
          name: :string,
          all: :boolean,
          skip_creation: :boolean,
          dry_run: :boolean
        ]
      )

    # Prepare options for import
    import_options = [
      create_movies: !opts[:skip_creation] && !opts[:dry_run]
    ]

    cond do
      opts[:list] ->
        import_predefined_list(opts[:list], import_options, opts[:dry_run])

      opts[:list_id] && opts[:source_key] && opts[:name] ->
        import_custom_list(opts, import_options, opts[:dry_run])

      opts[:all] ->
        import_all_predefined_lists(import_options, opts[:dry_run])

      true ->
        Mix.shell().error(
          "Please specify --list, --all, or provide --list-id, --source-key, and --name"
        )

        Mix.shell().info("\nUsage: mix import_canonical --list 1001_movies")

        Mix.shell().info(
          "       mix import_canonical --list-id ls024863935 --source-key 1001_movies --name \"1001 Movies\""
        )

        Mix.shell().info("       mix import_canonical --all")
    end
  end

  defp import_predefined_list(list_key, options, dry_run) do
    case Map.get(predefined_lists(), list_key) do
      nil ->
        Mix.shell().error("Unknown list: #{list_key}")
        Mix.shell().info("Available lists: #{Map.keys(predefined_lists()) |> Enum.join(", ")}")

      list_config ->
        Mix.shell().info(
          "#{if dry_run, do: "[DRY RUN] ", else: ""}Importing #{list_config.name}..."
        )

        if dry_run do
          show_list_preview(list_config)
        else
          result =
            Cinegraph.Cultural.CanonicalImporter.import_canonical_list(
              list_config.list_id,
              list_config.source_key,
              list_config.name,
              options,
              list_config[:metadata] || %{}
            )

          show_import_results(result)
        end
    end
  end

  defp import_custom_list(opts, import_options, dry_run) do
    list_id = opts[:list_id]
    source_key = opts[:source_key]
    name = opts[:name]

    Mix.shell().info("#{if dry_run, do: "[DRY RUN] ", else: ""}Importing custom list: #{name}...")

    if dry_run do
      show_list_preview(%{list_id: list_id, source_key: source_key, name: name})
    else
      result =
        Cinegraph.Cultural.CanonicalImporter.import_canonical_list(
          list_id,
          source_key,
          name,
          import_options
        )

      show_import_results(result)
    end
  end

  defp import_all_predefined_lists(options, dry_run) do
    Mix.shell().info(
      "#{if dry_run, do: "[DRY RUN] ", else: ""}Importing all predefined canonical lists..."
    )

    if dry_run do
      Enum.each(predefined_lists(), fn {_key, config} ->
        show_list_preview(config)
      end)
    else
      list_configs = Map.values(predefined_lists())

      results = Cinegraph.Cultural.CanonicalImporter.import_multiple_lists(list_configs, options)

      Mix.shell().info("\n📊 Import Summary:")
      Mix.shell().info("  • Lists processed: #{results.total_lists}")
      Mix.shell().info("  • Total movies: #{results.total_movies}")
      Mix.shell().info("  • Movies created: #{results.movies_created}")
      Mix.shell().info("  • Movies updated: #{results.movies_updated}")
      Mix.shell().info("  • Movies queued: #{results.movies_queued}")
      Mix.shell().info("  • Movies skipped: #{results.movies_skipped}")
      Mix.shell().info("  • Errors: #{results.errors}")
    end
  end

  defp show_list_preview(config) do
    Mix.shell().info("  • #{config.name}")
    Mix.shell().info("    Source Key: #{config.source_key}")
    Mix.shell().info("    IMDb List: https://www.imdb.com/list/#{config.list_id}/")

    if config[:metadata] do
      Mix.shell().info("    Metadata: #{inspect(config.metadata)}")
    end
  end

  defp show_import_results(result) do
    if result[:error] do
      Mix.shell().error("❌ Import failed: #{inspect(result.error)}")
    else
      Mix.shell().info("\n✅ Import completed successfully:")
      Mix.shell().info("  • Total movies: #{result.total_movies}")
      Mix.shell().info("  • Movies created: #{result.movies_created}")
      Mix.shell().info("  • Movies updated: #{result.movies_updated}")
      Mix.shell().info("  • Movies queued: #{result.movies_queued}")
      Mix.shell().info("  • Movies skipped: #{result.movies_skipped}")

      if result.movies_queued > 0 do
        Mix.shell().info(
          "\n📋 #{result.movies_queued} movies queued for creation via TMDbDetailsWorker"
        )

        Mix.shell().info("Monitor progress at: http://localhost:4001/dev/oban")
        Mix.shell().info("\nTo check canonical movie status in IEx:")
        Mix.shell().info("  Cinegraph.Cultural.CanonicalImporter.import_stats()")
      end
    end
  end
end
