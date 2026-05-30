defmodule Cinegraph.Auth.Clerk.JWTTest do
  # async: false — the JWKS ETS cache is a shared named table.
  use ExUnit.Case, async: false

  alias Cinegraph.Auth.Clerk.JWT
  import Cinegraph.ClerkTestHelpers

  setup do
    on_exit(&reset_cache/0)
    :ok
  end

  test "verifies a well-formed, correctly-signed token" do
    jwk = install_jwks()

    token =
      sign_token(jwk, %{"sub" => "user_abc", "userId" => "42", "azp" => "http://localhost:4000"})

    assert {:ok, claims} = JWT.verify_token(token)
    assert claims["sub"] == "user_abc"
    assert JWT.extract_user_id(claims) == 42
    assert JWT.extract_clerk_user_id(claims) == "user_abc"
  end

  test "rejects an expired token" do
    jwk = install_jwks()
    token = sign_token(jwk, %{"sub" => "user_abc", "exp" => System.system_time(:second) - 10})

    assert {:error, :expired} = JWT.verify_token(token)
  end

  test "rejects a token signed by a key not in the JWKS" do
    # Install one key, sign with a different key → signature won't match.
    install_jwks()
    other = JOSE.JWK.generate_key({:rsa, 2048})
    token = sign_token(other, %{"sub" => "user_abc"})

    assert {:error, :invalid_signature} = JWT.verify_token(token)
  end

  test "rejects an unauthorized party (azp)" do
    jwk = install_jwks()
    token = sign_token(jwk, %{"sub" => "user_abc", "azp" => "https://evil.example.com"})

    assert {:error, :invalid_authorized_party} = JWT.verify_token(token)
  end

  test "rejects non-binary input" do
    assert {:error, :invalid_token} = JWT.verify_token(nil)
  end

  test "fails closed when exp is missing (no non-expiring tokens)" do
    jwk = install_jwks()
    # Sign directly (bypassing the helper's default exp) to omit the claim.
    {_, token} =
      jwk |> JOSE.JWT.sign(%{"alg" => "RS256"}, %{"sub" => "user_abc"}) |> JOSE.JWS.compact()

    assert {:error, :missing_expiration} = JWT.verify_token(token)
  end

  test "rejects a token from a different issuer when issuer is configured" do
    original = Application.get_env(:cinegraph, :clerk, [])
    on_exit(fn -> Application.put_env(:cinegraph, :clerk, original) end)

    Application.put_env(
      :cinegraph,
      :clerk,
      Keyword.put(original, :issuer, "https://clerk.cinegraph.org")
    )

    jwk = install_jwks()

    bad = sign_token(jwk, %{"sub" => "u", "iss" => "https://evil.clerk.accounts.dev"})
    assert {:error, :invalid_issuer} = JWT.verify_token(bad)

    good = sign_token(jwk, %{"sub" => "u", "iss" => "https://clerk.cinegraph.org"})
    assert {:ok, %{"sub" => "u"}} = JWT.verify_token(good)
  end
end
