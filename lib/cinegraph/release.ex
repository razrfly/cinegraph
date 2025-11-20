defmodule Cinegraph.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :cinegraph

  def migrate do
    load_app()

    for repo <- repos() do
      case Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true)) do
        {:ok, _, _} ->
          IO.puts("Migrations successful for #{inspect(repo)}")

        {:error, reason} ->
          IO.warn("Migration failed for #{inspect(repo)}: #{inspect(reason)}")
          raise "Migration failed for #{inspect(repo)}"
      end
    end

    # Run seeds after migrations
    seed()

    :ok
  end

  def rollback(repo, version) do
    load_app()

    case Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version)) do
      {:ok, _, _} ->
        IO.puts("Rollback to version #{version} successful for #{inspect(repo)}")
        :ok

      {:error, reason} ->
        IO.warn("Rollback failed for #{inspect(repo)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def seed do
    load_app()

    # Start the Repo before running seeds
    for repo <- repos() do
      {:ok, _} = repo.start_link(pool_size: 2)
    end

    seed_script = Path.join([priv_dir(@app), "repo", "seeds.exs"])

    if File.exists?(seed_script) do
      IO.puts("Running seed script...")
      Code.eval_file(seed_script)
      IO.puts("Seed script completed successfully")
    else
      IO.warn("Seed script not found at #{seed_script}")
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    case Application.load(@app) do
      :ok ->
        :ok

      {:error, {:already_loaded, @app}} ->
        :ok

      {:error, reason} ->
        raise "Failed to load application: #{inspect(reason)}"
    end
  end

  defp priv_dir(app), do: "#{:code.priv_dir(app)}"
end
