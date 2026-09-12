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

  @doc "Creates an API client and returns JSON-serializable client metadata."
  def api_client_create(attrs) when is_map(attrs) do
    start_app!()

    case Cinegraph.ApiCredentials.create_client(Map.put(attrs, :scopes, ["catalog:read"])) do
      {:ok, client} -> success(%{client: client_json(client)})
      {:error, reason} -> failure(reason)
    end
  end

  @doc "Lists API clients without credential material."
  def api_client_list do
    start_app!()
    success(%{clients: Enum.map(Cinegraph.ApiCredentials.list_clients(), &client_json/1)})
  end

  @doc "Disables a client immediately for all new authentication lookups."
  def api_client_disable(slug) do
    start_app!()

    case Cinegraph.ApiCredentials.disable_client(slug) do
      {:ok, client} -> success(%{client: client_json(client)})
      {:error, reason} -> failure(reason)
    end
  end

  @doc "Issues a key and returns its plaintext once. `expires_at` must be explicit, including nil."
  def api_key_issue(slug, %{expires_at: _} = attrs) do
    start_app!()

    case Cinegraph.ApiCredentials.issue_key(slug, attrs) do
      {:ok, key, token} ->
        success(%{key: key_json(key), token: token})

      {:error, reason} ->
        failure(reason)
    end
  end

  @doc "Issues an overlapping rotation key; the old key is not revoked."
  def api_key_rotate(slug, old_public_id, %{expires_at: _} = attrs) do
    start_app!()

    case Cinegraph.ApiCredentials.rotate_key(slug, old_public_id, attrs) do
      {:ok, key, token} ->
        success(%{
          key: key_json(key),
          token: token,
          replaced_public_id: old_public_id,
          old_key_status: "active_until_revoked"
        })

      {:error, reason} ->
        failure(reason)
    end
  end

  @doc "Lists key metadata without digests or plaintext secrets."
  def api_key_list(slug) do
    start_app!()

    case Cinegraph.ApiCredentials.list_keys(slug) do
      {:ok, keys} ->
        success(%{keys: Enum.map(keys, &key_json/1)})

      {:error, reason} ->
        failure(reason)
    end
  end

  @doc "Revokes a key by its non-secret public ID."
  def api_key_revoke(public_id) do
    start_app!()

    case Cinegraph.ApiCredentials.revoke_key(public_id) do
      {:ok, key} -> success(%{key: key_json(key)})
      {:error, reason} -> failure(reason)
    end
  end

  @doc "Dispatches a credential operation from string-keyed, JSON-decoded parameters."
  def api_credential_command("client-create", params) do
    api_client_create(%{
      slug: params["slug"],
      label: params["label"],
      owner_contact: params["owner_contact"],
      environment: params["environment"]
    })
  end

  def api_credential_command("client-list", _params), do: api_client_list()

  def api_credential_command("client-disable", params) do
    api_client_disable(params["slug"])
  end

  def api_credential_command("key-issue", params) do
    with {:ok, expires_at} <- command_expiry(params) do
      api_key_issue(params["client"], %{
        label: params["label"],
        created_by: params["created_by"],
        expires_at: expires_at
      })
    else
      {:error, reason} -> failure(reason)
    end
  end

  def api_credential_command("key-rotate", params) do
    with {:ok, expires_at} <- command_expiry(params) do
      api_key_rotate(params["client"], params["old_public_id"], %{
        label: params["label"],
        created_by: params["created_by"],
        expires_at: expires_at
      })
    else
      {:error, reason} -> failure(reason)
    end
  end

  def api_credential_command("key-list", params), do: api_key_list(params["client"])
  def api_credential_command("key-revoke", params), do: api_key_revoke(params["public_id"])
  def api_credential_command(_command, _params), do: failure(:unknown_command)

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

  defp command_expiry(%{"expires_at" => nil}), do: {:ok, nil}

  defp command_expiry(%{"expires_at" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _ -> {:error, :invalid_expiry}
    end
  end

  defp command_expiry(_params), do: {:error, :expiry_required}

  defp client_json(client) do
    %{
      id: client.id,
      slug: client.slug,
      label: client.label,
      owner_contact: client.owner_contact,
      environment: client.environment,
      enabled: client.enabled,
      scopes: client.scopes,
      inserted_at: iso8601(client.inserted_at),
      updated_at: iso8601(client.updated_at)
    }
  end

  defp key_json(key) do
    %{
      id: key.id,
      client_id: key.api_client_id,
      public_id: key.public_id,
      label: key.label,
      expires_at: iso8601(key.expires_at),
      revoked_at: iso8601(key.revoked_at),
      last_used_at: iso8601(key.last_used_at),
      created_by: key.created_by,
      inserted_at: iso8601(key.inserted_at),
      updated_at: iso8601(key.updated_at)
    }
  end

  defp success(data), do: Map.put(data, :ok, true)

  defp failure(%Ecto.Changeset{} = changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
        Enum.reduce(options, message, fn {key, value}, rendered ->
          String.replace(rendered, "%{#{key}}", to_string(value))
        end)
      end)

    %{ok: false, error: "validation_failed", details: errors}
  end

  defp failure(reason) when is_atom(reason), do: %{ok: false, error: Atom.to_string(reason)}
  defp failure(_reason), do: %{ok: false, error: "operation_failed"}

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)

  defp priv_dir(app), do: "#{:code.priv_dir(app)}"
end
