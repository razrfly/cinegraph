defmodule Cinegraph.Workers.SitemapWorker do
  @moduledoc """
  Oban worker for generating the sitemap.

  Scheduled to run daily at 2 AM UTC via cron.
  Can also be triggered manually from the Oban dashboard or via:

      Cinegraph.Workers.SitemapWorker.new(%{}) |> Oban.insert()

  The sitemap generation is a long-running process that streams all
  movies, people, lists, and awards from the database.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    priority: 3

  require Logger

  alias Cinegraph.Sitemap

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    Logger.info("Starting scheduled sitemap generation")

    # Allow host override from job args (useful for testing)
    opts = if args["host"], do: [host: args["host"]], else: []

    case Sitemap.generate_and_persist(opts) do
      :ok ->
        counts = Sitemap.url_count()
        Logger.info("Sitemap generation completed: #{counts.total} URLs indexed")
        Logger.info("  - Static pages: #{counts.static}")
        Logger.info("  - Movies: #{counts.movies}")
        Logger.info("  - People: #{counts.people}")
        Logger.info("  - Lists: #{counts.lists}")
        Logger.info("  - Awards: #{counts.awards}")
        :ok

      {:error, reason} ->
        Logger.error("Sitemap generation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Enqueue a sitemap generation job immediately.
  Returns {:ok, job} on success.
  """
  def enqueue_now(opts \\ []) do
    args = if host = Keyword.get(opts, :host), do: %{"host" => host}, else: %{}

    %{}
    |> Map.merge(args)
    |> __MODULE__.new()
    |> Oban.insert()
  end
end
