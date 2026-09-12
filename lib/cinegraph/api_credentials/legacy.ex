defmodule Cinegraph.ApiCredentials.Legacy do
  @moduledoc false

  alias Cinegraph.ApiCredentials.Principal

  @catalog_scope "catalog:read"

  def configured_token?(token) when is_binary(token) do
    case Application.get_env(:cinegraph, :legacy_api_key) do
      configured when is_binary(configured) ->
        String.trim(configured) != "" and same_size_secure_compare(token, configured)

      _ ->
        false
    end
  end

  def configured_token?(_), do: false

  def authenticate(token, now \\ DateTime.utc_now()) when is_binary(token) do
    configured = Application.get_env(:cinegraph, :legacy_api_key)
    expires_at = Application.get_env(:cinegraph, :legacy_api_key_expires_at)

    result =
      cond do
        not non_blank?(configured) ->
          {:error, :unconfigured}

        not match?(%DateTime{}, expires_at) ->
          {:error, :unconfigured}

        DateTime.compare(now, expires_at) != :lt ->
          {:error, :expired}

        not same_size_secure_compare(token, configured) ->
          {:error, :invalid}

        true ->
          {:ok,
           %Principal{
             client_id: "legacy",
             key_id: "legacy",
             client_slug: "legacy-shared-key",
             scopes: [@catalog_scope],
             kind: :legacy
           }}
      end

    metadata =
      case result do
        {:ok, principal} ->
          %{
            outcome: :ok,
            auth_kind: :legacy,
            client_id: principal.client_id,
            key_id: principal.key_id,
            client_slug: principal.client_slug
          }

        {:error, reason} ->
          %{outcome: reason, auth_kind: :legacy, client_id: nil, key_id: nil, client_slug: nil}
      end

    :telemetry.execute([:cinegraph, :api_auth, :stop], %{count: 1}, metadata)
    result
  end

  defp non_blank?(value), do: is_binary(value) and String.trim(value) != ""

  # secure_compare requires equal byte sizes; hashing both values makes the
  # comparison constant-time even for a wrong-length attacker-controlled token.
  defp same_size_secure_compare(left, right) do
    Plug.Crypto.secure_compare(:crypto.hash(:sha256, left), :crypto.hash(:sha256, right))
  end
end
