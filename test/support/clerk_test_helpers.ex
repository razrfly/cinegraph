defmodule Cinegraph.ClerkTestHelpers do
  @moduledoc """
  Helpers for testing Clerk JWT verification (#838) without hitting the network.

  Generates an in-memory RSA keypair, seeds the public key into the JWKS ETS
  cache that `Cinegraph.Auth.Clerk.JWT` reads, and signs tokens with the private
  key so `verify_token/1` succeeds offline.
  """

  @jwks_table :clerk_jwks_cache

  @doc """
  Generates a fresh RSA keypair and installs its public JWK into the JWKS cache.
  Returns the private `JOSE.JWK` to sign tokens with.
  """
  def install_jwks do
    private_jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public_map} = JOSE.JWK.to_public_map(private_jwk)

    public_map =
      Map.merge(public_map, %{"kid" => "test-key", "alg" => "RS256", "use" => "sig"})

    seed_cache([public_map])
    private_jwk
  end

  @doc """
  Seeds an arbitrary list of JWK maps into the cache (e.g. to force a signature
  mismatch by installing a key that did NOT sign the token).
  """
  def seed_cache(jwk_maps) do
    reset_cache()
    expires_at = System.system_time(:millisecond) + 3_600_000
    :ets.insert(@jwks_table, {:jwks, jwk_maps, expires_at})
    :ok
  end

  @doc """
  Removes the cached JWKS so tests don't leak state into each other.
  """
  def reset_cache do
    case :ets.whereis(@jwks_table) do
      :undefined -> :ets.new(@jwks_table, [:set, :public, :named_table])
      _ -> :ets.delete_all_objects(@jwks_table)
    end

    :ok
  end

  @doc """
  Signs a JWT with the given private key and claims (RS256), returning the
  compact token string. Sets a default `exp` 1 hour in the future unless given.
  """
  def sign_token(private_jwk, claims) do
    claims =
      Map.merge(%{"exp" => System.system_time(:second) + 3600}, claims)

    {_, token} =
      private_jwk
      |> JOSE.JWT.sign(%{"alg" => "RS256"}, claims)
      |> JOSE.JWS.compact()

    token
  end
end
