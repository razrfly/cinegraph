defmodule Mix.Tasks.Sitemap.Generate do
  @moduledoc """
  Mix task to manually generate the sitemap.

  ## Usage

      mix sitemap.generate

  ## Options

      --host    Override the host URL (default: https://cinegraph.io)
      --stats   Only show URL counts without generating

  ## Examples

      # Generate sitemap with default settings
      mix sitemap.generate

      # Generate sitemap for a different host
      mix sitemap.generate --host http://localhost:4000

      # Just show URL counts
      mix sitemap.generate --stats
  """

  use Mix.Task

  @shortdoc "Generate the sitemap"

  @impl Mix.Task
  def run(args) do
    # Start the application
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      strict: [host: :string, stats: :boolean]
    )

    if opts[:stats] do
      show_stats()
    else
      generate_sitemap(opts)
    end
  end

  defp show_stats do
    Mix.shell().info("Calculating sitemap URL counts...")

    counts = Cinegraph.Sitemap.url_count()

    Mix.shell().info("")
    Mix.shell().info("Sitemap URL Counts:")
    Mix.shell().info("  Static pages: #{counts.static}")
    Mix.shell().info("  Movies:       #{counts.movies}")
    Mix.shell().info("  People:       #{counts.people}")
    Mix.shell().info("  Lists:        #{counts.lists}")
    Mix.shell().info("  Awards:       #{counts.awards}")
    Mix.shell().info("  ─────────────────────")
    Mix.shell().info("  Total:        #{counts.total}")
    Mix.shell().info("")

    # Estimate file count (Sitemapper creates a new file every 50,000 URLs)
    file_count = ceil(counts.total / 50_000)
    Mix.shell().info("Estimated sitemap files: #{file_count}")
  end

  defp generate_sitemap(opts) do
    Mix.shell().info("Starting sitemap generation...")

    sitemap_opts = if opts[:host], do: [host: opts[:host]], else: []

    # Show initial stats
    counts = Cinegraph.Sitemap.url_count()
    Mix.shell().info("URLs to index: #{counts.total}")

    case Cinegraph.Sitemap.generate_and_persist(sitemap_opts) do
      :ok ->
        Mix.shell().info("")
        Mix.shell().info("✓ Sitemap generated successfully!")
        Mix.shell().info("")
        show_generated_files()

      {:error, reason} ->
        Mix.shell().error("✗ Sitemap generation failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp show_generated_files do
    sitemap_dir = Path.join([:code.priv_dir(:cinegraph), "static", "sitemaps"])

    if File.exists?(sitemap_dir) do
      files = File.ls!(sitemap_dir)
        |> Enum.filter(&String.ends_with?(&1, ".xml"))
        |> Enum.sort()

      Mix.shell().info("Generated files in #{sitemap_dir}:")
      for file <- files do
        path = Path.join(sitemap_dir, file)
        stat = File.stat!(path)
        size_kb = Float.round(stat.size / 1024, 1)
        Mix.shell().info("  #{file} (#{size_kb} KB)")
      end
    else
      Mix.shell().info("Sitemap directory not found: #{sitemap_dir}")
    end
  end
end
