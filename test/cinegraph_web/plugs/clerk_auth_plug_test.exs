defmodule CinegraphWeb.Plugs.ClerkAuthPlugTest do
  # async: false — shares the global JWKS ETS cache.
  use CinegraphWeb.ConnCase, async: false

  import Cinegraph.ClerkTestHelpers
  import Plug.Conn

  alias CinegraphWeb.Plugs.ClerkAuthPlug

  setup %{conn: conn} do
    on_exit(&reset_cache/0)
    {:ok, conn: init_test_session(conn, %{})}
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  describe "fetch_clerk_user/2 + sync_clerk_user/2" do
    test "assigns auth_user and a synced current_user for a valid token", %{conn: conn} do
      jwk = install_jwks()

      token =
        sign_token(jwk, %{
          "sub" => "user_x",
          "email" => "plug@example.com",
          "first_name" => "Plug"
        })

      conn =
        conn
        |> bearer(token)
        |> ClerkAuthPlug.fetch_clerk_user([])
        |> ClerkAuthPlug.sync_clerk_user([])

      assert conn.assigns.auth_user["sub"] == "user_x"
      assert conn.assigns.current_user.email == "plug@example.com"
      assert get_session(conn, "current_user_id") == conn.assigns.current_user.id
    end

    test "assigns nil for an absent token", %{conn: conn} do
      conn =
        conn
        |> ClerkAuthPlug.fetch_clerk_user([])
        |> ClerkAuthPlug.sync_clerk_user([])

      assert conn.assigns.auth_user == nil
      assert conn.assigns.current_user == nil
    end

    test "assigns nil for an invalid token", %{conn: conn} do
      install_jwks()
      other = JOSE.JWK.generate_key({:rsa, 2048})
      token = sign_token(other, %{"sub" => "user_x"})

      conn =
        conn
        |> bearer(token)
        |> ClerkAuthPlug.fetch_clerk_user([])
        |> ClerkAuthPlug.sync_clerk_user([])

      assert conn.assigns.auth_user == nil
      assert conn.assigns.current_user == nil
    end
  end

  describe "require_authenticated_clerk_user/2" do
    test "redirects to login when unauthenticated", %{conn: conn} do
      conn =
        conn
        |> fetch_flash()
        |> assign(:current_user, nil)
        |> ClerkAuthPlug.require_authenticated_clerk_user([])

      assert conn.halted
      assert redirected_to(conn) == "/auth/login"
    end

    test "passes through when a current_user is assigned", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> ClerkAuthPlug.require_authenticated_clerk_user([])

      refute conn.halted
    end
  end

  describe "require_authenticated_clerk_api_user/2" do
    test "returns 401 JSON when unauthenticated", %{conn: conn} do
      conn =
        conn
        |> assign(:current_user, nil)
        |> ClerkAuthPlug.require_authenticated_clerk_api_user([])

      assert conn.halted
      assert conn.status == 401
      assert conn.resp_body =~ "unauthorized"
    end
  end
end
