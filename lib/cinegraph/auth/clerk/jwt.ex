defmodule Cinegraph.Auth.Clerk.JWT do
  @moduledoc """
  JWT verification for Clerk session tokens.

  This module handles verification of Clerk JWT tokens using JOSE.
  It fetches and caches JWKS (JSON Web Key Set) from Clerk for token verification.

  ## How It Works

  1. Client sends session token (from `__session` cookie or Authorization header)
  2. This module fetches Clerk's JWKS to get public keys
  3. Token is verified against the public key
  4. Claims are validated (expiration, authorized parties, etc.)
  5. Returns the verified claims including `sub` (Clerk ID) and `userId` (our users.id)

  ## Architecture

  Our `users.id` (integer primary key) is the canonical identifier.
  Clerk stores this as `external_id`, and JWT claims include it as `userId`.

  ## Usage

      case JWT.verify_token(token) do
        {:ok, claims} ->
          # claims["sub"] is the Clerk user ID (e.g., "user_abc123")
          # claims["userId"] is our users.id (integer, as string)
          user_id = claims["userId"]  # "19" -> parse to integer

        {:error, reason} ->
          # Token is invalid
      end
  """

  require Logger

  # Cache JWKS for 1 hour (can be configured)
  @default_cache_ttl 3_600_000

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Verify a Clerk session token and return the claims.

  ## Returns

    * `{:ok, claims}` - Token is valid, returns decoded claims map
    * `{:error, :invalid_token}` - Token format is invalid
    * `{:error, :expired}` - Token has expired
    * `{:error, :not_yet_valid}` - Token's nbf claim is in the future
    * `{:error, :invalid_signature}` - Token signature doesn't match
    * `{:error, :invalid_authorized_party}` - Token's azp claim not in allowed list
    * `{:error, reason}` - Other verification failure

  ## Examples

      {:ok, claims} = JWT.verify_token("eyJhbG...")
      user_id = claims["sub"]
  """
  def verify_token(token) when is_binary(token) do
    with {:ok, jwks} <- fetch_jwks(),
         {:ok, claims} <- verify_with_jwks(token, jwks),
         :ok <- validate_claims(claims) do
      {:ok, claims}
    end
  end

  def verify_token(_), do: {:error, :invalid_token}

  @doc """
  Extract the user ID from verified claims.

  Returns our users.id (integer) from the userId claim.
  Falls back to nil if not present (new Clerk signup without external_id).
  """
  def extract_user_id(claims) when is_map(claims) do
    case claims["userId"] do
      nil ->
        nil

      id when is_integer(id) ->
        id

      id when is_binary(id) ->
        case Integer.parse(id) do
          {int_id, ""} -> int_id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def extract_user_id(_), do: nil

  @doc """
  Extract the Clerk user ID from claims.

  Always returns the Clerk user ID (sub claim), not the external_id.
  """
  def extract_clerk_user_id(claims) when is_map(claims) do
    claims["sub"]
  end

  def extract_clerk_user_id(_), do: nil

  # ============================================================================
  # JWKS Fetching and Caching
  # ============================================================================

  defp fetch_jwks do
    # Check cache first
    case get_cached_jwks() do
      {:ok, jwks} ->
        {:ok, jwks}

      :miss ->
        # Fetch from Clerk
        case fetch_jwks_from_clerk() do
          {:ok, jwks} ->
            cache_jwks(jwks)
            {:ok, jwks}

          error ->
            error
        end
    end
  end

  defp fetch_jwks_from_clerk do
    jwks_url = get_config(:jwks_url)

    if is_nil(jwks_url) do
      Logger.error("Clerk JWKS URL not configured")
      {:error, :jwks_not_configured}
    else
      case HTTPoison.get(jwks_url, [], recv_timeout: 10_000) do
        {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
          case Jason.decode(body) do
            {:ok, %{"keys" => keys}} ->
              {:ok, keys}

            {:error, _} ->
              Logger.error("Failed to parse JWKS response")
              {:error, :invalid_jwks}
          end

        {:ok, %HTTPoison.Response{status_code: status}} ->
          Logger.error("Failed to fetch JWKS: status=#{status}")
          {:error, :jwks_fetch_failed}

        {:error, reason} ->
          Logger.error("JWKS request failed: #{inspect(reason)}")
          {:error, :jwks_fetch_failed}
      end
    end
  end

  # Simple ETS-based cache for JWKS
  defp get_cached_jwks do
    case :ets.whereis(:clerk_jwks_cache) do
      :undefined ->
        :miss

      _table ->
        case :ets.lookup(:clerk_jwks_cache, :jwks) do
          [{:jwks, jwks, expires_at}] ->
            if System.system_time(:millisecond) < expires_at do
              {:ok, jwks}
            else
              :miss
            end

          [] ->
            :miss
        end
    end
  end

  defp cache_jwks(jwks) do
    # Create table if it doesn't exist - handle race condition with try/rescue
    try do
      :ets.new(:clerk_jwks_cache, [:set, :public, :named_table])
    rescue
      ArgumentError ->
        # Table already exists, that's fine
        :ok
    end

    ttl = get_config(:jwks_cache_ttl) || @default_cache_ttl
    expires_at = System.system_time(:millisecond) + ttl
    :ets.insert(:clerk_jwks_cache, {:jwks, jwks, expires_at})
  end

  # ============================================================================
  # Token Verification
  # ============================================================================

  defp verify_with_jwks(token, jwks) do
    # Try to verify with each key until one works
    # Clerk typically returns multiple keys for key rotation
    Enum.reduce_while(jwks, {:error, :invalid_signature}, fn jwk, acc ->
      case verify_with_key(token, jwk) do
        {:ok, claims} -> {:halt, {:ok, claims}}
        {:error, _} -> {:cont, acc}
      end
    end)
  end

  defp verify_with_key(token, jwk) do
    try do
      # Convert JWK map to JOSE JWK struct
      jose_jwk = JOSE.JWK.from_map(jwk)

      # verify_strict pins the allowed algorithm (Clerk signs with RS256) so a
      # token can't downgrade us into an algorithm-confusion attack (e.g. "none"
      # or an HMAC alg verified against the public key as a shared secret).
      case JOSE.JWT.verify_strict(jose_jwk, ["RS256"], token) do
        {true, %JOSE.JWT{fields: claims}, _jws} ->
          {:ok, claims}

        {false, _, _} ->
          {:error, :invalid_signature}
      end
    rescue
      e ->
        Logger.debug("JWT verification error: #{inspect(e)}")
        {:error, :verification_failed}
    end
  end

  # ============================================================================
  # Claims Validation
  # ============================================================================

  defp validate_claims(claims) do
    with :ok <- validate_expiration(claims),
         :ok <- validate_not_before(claims),
         :ok <- validate_issuer(claims),
         :ok <- validate_authorized_party(claims) do
      :ok
    end
  end

  # Fail closed: a session token without a valid integer `exp` is treated as
  # invalid rather than accepted as non-expiring. Clerk always sets `exp`.
  defp validate_expiration(claims) do
    case claims["exp"] do
      exp when is_integer(exp) ->
        if exp > System.system_time(:second), do: :ok, else: {:error, :expired}

      _ ->
        {:error, :missing_expiration}
    end
  end

  # Reject a validly-signed token issued by a *different* Clerk tenant by
  # checking `iss` against the configured issuer (https://<frontend-api-domain>).
  # Skipped when no issuer is configured (dev/test convenience), mirroring azp.
  defp validate_issuer(claims) do
    expected = expected_issuer()

    cond do
      is_nil(expected) ->
        :ok

      claims["iss"] == expected ->
        :ok

      true ->
        Logger.warning("Invalid issuer: #{inspect(claims["iss"])}, expected: #{expected}")
        {:error, :invalid_issuer}
    end
  end

  defp expected_issuer do
    case get_config(:issuer) do
      iss when is_binary(iss) and iss != "" -> iss
      _ -> if domain = get_config(:domain), do: "https://#{domain}"
    end
  end

  defp validate_not_before(claims) do
    case claims["nbf"] do
      nil ->
        :ok

      nbf when is_integer(nbf) ->
        now = System.system_time(:second)

        if nbf <= now do
          :ok
        else
          {:error, :not_yet_valid}
        end

      _ ->
        :ok
    end
  end

  defp validate_authorized_party(claims) do
    authorized_parties = get_config(:authorized_parties) || []
    azp = claims["azp"]

    cond do
      # No azp claim - skip validation
      is_nil(azp) ->
        :ok

      # No authorized parties configured - skip validation
      authorized_parties == [] ->
        :ok

      # Check if azp is in the allowed list
      azp in authorized_parties ->
        :ok

      true ->
        Logger.warning(
          "Invalid authorized party: #{azp}, allowed: #{inspect(authorized_parties)}"
        )

        {:error, :invalid_authorized_party}
    end
  end

  # ============================================================================
  # Configuration
  # ============================================================================

  defp get_config(key) do
    Application.get_env(:cinegraph, :clerk, [])
    |> Keyword.get(key)
  end
end
