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

    # NOTE: Seeds are intentionally NOT run here. `migrate/0` runs synchronously
    # on every deploy before the server boots; running the full idempotent
    # seeds.exs (plus a second repo pool) on every deploy added Postgres load
    # during the most fragile part of the deploy window and contributed to
    # health-check timeouts. Run seeds manually instead:
    #
    #     bin/cinegraph eval Cinegraph.Release.seed
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

  @doc "Creates an API client from a map; safe to call with `bin/cinegraph eval`."
  def api_client_create(attrs) when is_map(attrs) do
    start_app!()

    case Cinegraph.ApiCredentials.create_client(Map.put(attrs, :scopes, ["catalog:read"])) do
      {:ok, client} ->
        IO.puts("created client #{client.slug} (id=#{client.id})")
        :ok

      {:error, reason} ->
        raise "client creation failed: #{inspect(reason)}"
    end
  end

  @doc "Lists API clients without credential material."
  def api_client_list do
    start_app!()

    Enum.each(Cinegraph.ApiCredentials.list_clients(), fn client ->
      IO.puts(
        "#{client.slug}\tid=#{client.id}\tenvironment=#{client.environment}\tenabled=#{client.enabled}\tscopes=#{Enum.join(client.scopes, ",")}\towner=#{client.owner_contact}"
      )
    end)
  end

  @doc "Disables a client immediately for all new authentication lookups."
  def api_client_disable(slug) do
    start_app!()

    case Cinegraph.ApiCredentials.disable_client(slug) do
      {:ok, client} -> IO.puts("disabled client #{client.slug} (id=#{client.id})")
      {:error, reason} -> raise "client disable failed: #{inspect(reason)}"
    end
  end

  @doc "Issues a key and prints its plaintext once. `expires_at` must be explicit, including nil."
  def api_key_issue(slug, %{expires_at: _} = attrs) do
    start_app!()

    case Cinegraph.ApiCredentials.issue_key(slug, attrs) do
      {:ok, key, token} ->
        IO.puts("issued key #{key.public_id} for client #{slug}")
        IO.puts("CINEGRAPH_API_KEY=#{token}")
        :ok

      {:error, reason} ->
        raise "key issuance failed: #{inspect(reason)}"
    end
  end

  @doc "Issues an overlapping rotation key; the old key is not revoked."
  def api_key_rotate(slug, old_public_id, %{expires_at: _} = attrs) do
    :ok = api_key_issue(slug, attrs)
    IO.puts("old key #{old_public_id} remains valid; deploy and verify before revoking it")
  end

  @doc "Lists key metadata without digests or plaintext secrets."
  def api_key_list(slug) do
    start_app!()

    case Cinegraph.ApiCredentials.list_keys(slug) do
      {:ok, keys} ->
        Enum.each(keys, fn key ->
          IO.puts(
            "#{key.public_id}\tid=#{key.id}\tlabel=#{key.label}\texpires_at=#{format_time(key.expires_at)}\trevoked_at=#{format_time(key.revoked_at)}\tcreated_by=#{key.created_by}"
          )
        end)

      {:error, reason} ->
        raise "key listing failed: #{inspect(reason)}"
    end
  end

  @doc "Revokes a key by its non-secret public ID."
  def api_key_revoke(public_id) do
    start_app!()

    case Cinegraph.ApiCredentials.revoke_key(public_id) do
      {:ok, key} -> IO.puts("revoked key #{key.public_id}")
      {:error, reason} -> raise "key revocation failed: #{inspect(reason)}"
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

  defp start_app! do
    load_app()

    case Application.ensure_all_started(@app) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Failed to start application: #{inspect(reason)}"
    end
  end

  defp format_time(nil), do: "never"
  defp format_time(datetime), do: DateTime.to_iso8601(datetime)

  defp priv_dir(app), do: "#{:code.priv_dir(app)}"
end
