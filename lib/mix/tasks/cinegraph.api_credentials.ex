defmodule Mix.Tasks.Cinegraph.ApiCredentials do
  use Mix.Task

  @shortdoc "Manage catalog API clients and credentials"

  @moduledoc """
  Manages the per-consumer API credential registry.

      mix cinegraph.api_credentials client-create --slug wordhoard-preview \
        --label "Wordhoard preview" --owner-contact ops@example.com --environment preview
      mix cinegraph.api_credentials client-list
      mix cinegraph.api_credentials client-disable --slug wordhoard-preview
      mix cinegraph.api_credentials key-issue --client wordhoard-preview \
        --label initial --created-by operator@example.com --no-expiry
      mix cinegraph.api_credentials key-list --client wordhoard-preview
      mix cinegraph.api_credentials key-revoke --public-id PUBLIC_ID
      mix cinegraph.api_credentials key-rotate --client wordhoard-preview \
        --old-public-id PUBLIC_ID --label rotation --created-by operator@example.com --no-expiry

  Plaintext is printed exactly once by `key-issue` and `key-rotate`. Listing
  commands never print a secret. Rotation creates an overlapping key and leaves
  the old key valid until a separate `key-revoke` after consumer verification.
  """

  alias Cinegraph.ApiCredentials

  @switches [
    slug: :string,
    label: :string,
    owner_contact: :string,
    environment: :string,
    client: :string,
    created_by: :string,
    expires_at: :string,
    no_expiry: :boolean,
    public_id: :string,
    old_public_id: :string
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    case {positional, Map.new(opts)} do
      {["client-create"], opts} -> create_client(opts)
      {["client-list"], _opts} -> list_clients()
      {["client-disable"], opts} -> disable_client(opts)
      {["key-issue"], opts} -> issue_key(opts, false)
      {["key-rotate"], opts} -> issue_key(opts, true)
      {["key-list"], opts} -> list_keys(opts)
      {["key-revoke"], opts} -> revoke_key(opts)
      _ -> Mix.raise("unknown or malformed command; run `mix help cinegraph.api_credentials`")
    end
  end

  defp create_client(opts) do
    attrs = %{
      slug: required!(opts, :slug),
      label: required!(opts, :label),
      owner_contact: required!(opts, :owner_contact),
      environment: required!(opts, :environment),
      scopes: ["catalog:read"]
    }

    case ApiCredentials.create_client(attrs) do
      {:ok, client} -> Mix.shell().info("created client #{client.slug} (id=#{client.id})")
      {:error, reason} -> fail!(reason)
    end
  end

  defp list_clients do
    Enum.each(ApiCredentials.list_clients(), fn client ->
      Mix.shell().info(
        "#{client.slug}\tid=#{client.id}\tenvironment=#{client.environment}\tenabled=#{client.enabled}\tscopes=#{Enum.join(client.scopes, ",")}\towner=#{client.owner_contact}"
      )
    end)
  end

  defp disable_client(opts) do
    case ApiCredentials.disable_client(required!(opts, :slug)) do
      {:ok, client} -> Mix.shell().info("disabled client #{client.slug} (id=#{client.id})")
      {:error, reason} -> fail!(reason)
    end
  end

  defp issue_key(opts, rotation?) do
    if rotation?, do: required!(opts, :old_public_id)

    attrs = %{
      label: required!(opts, :label),
      created_by: required!(opts, :created_by),
      expires_at: expiry!(opts)
    }

    operation =
      if rotation?,
        do:
          ApiCredentials.rotate_key(
            required!(opts, :client),
            required!(opts, :old_public_id),
            attrs
          ),
        else: ApiCredentials.issue_key(required!(opts, :client), attrs)

    case operation do
      {:ok, key, token} ->
        Mix.shell().info("issued key #{key.public_id} for client #{opts.client}")
        Mix.shell().info("CINEGRAPH_API_KEY=#{token}")

        if rotation? do
          Mix.shell().info(
            "old key #{opts.old_public_id} remains valid; deploy and verify before revoking it"
          )
        end

      {:error, reason} ->
        fail!(reason)
    end
  end

  defp list_keys(opts) do
    case ApiCredentials.list_keys(required!(opts, :client)) do
      {:ok, keys} ->
        Enum.each(keys, fn key ->
          Mix.shell().info(
            "#{key.public_id}\tid=#{key.id}\tlabel=#{key.label}\texpires_at=#{format_time(key.expires_at)}\trevoked_at=#{format_time(key.revoked_at)}\tcreated_by=#{key.created_by}"
          )
        end)

      {:error, reason} ->
        fail!(reason)
    end
  end

  defp revoke_key(opts) do
    case ApiCredentials.revoke_key(required!(opts, :public_id)) do
      {:ok, key} -> Mix.shell().info("revoked key #{key.public_id}")
      {:error, reason} -> fail!(reason)
    end
  end

  defp expiry!(%{no_expiry: true} = opts) do
    if Map.has_key?(opts, :expires_at),
      do: Mix.raise("choose --expires-at or --no-expiry, not both")

    nil
  end

  defp expiry!(%{expires_at: value}) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> datetime
      _ -> Mix.raise("--expires-at must be an ISO 8601 UTC timestamp")
    end
  end

  defp expiry!(_), do: Mix.raise("choose an explicit --expires-at or --no-expiry")

  defp required!(opts, key) do
    case Map.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      _ -> Mix.raise("missing --#{key |> Atom.to_string() |> String.replace("_", "-")}")
    end
  end

  defp format_time(nil), do: "never"
  defp format_time(datetime), do: DateTime.to_iso8601(datetime)
  defp fail!(%Ecto.Changeset{} = changeset), do: Mix.raise(inspect(changeset.errors))
  defp fail!(reason), do: Mix.raise(inspect(reason))
end
