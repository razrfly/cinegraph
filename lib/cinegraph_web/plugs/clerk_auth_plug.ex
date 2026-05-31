defmodule CinegraphWeb.Plugs.ClerkAuthPlug do
  @moduledoc """
  Authentication plugs for Clerk-based authentication.

  Manages the dual assignment pattern:

  - `conn.assigns.auth_user`: raw Clerk JWT claims (internal use)
  - `conn.assigns.current_user`: local `%Cinegraph.Accounts.User{}` (business logic)

  ## Token Sources

  1. `Authorization: Bearer <token>` header (API/mobile)
  2. `__session` cookie (set by Clerk.js for browser requests)

  ## Usage

      pipeline :clerk_auth do
        plug :fetch_clerk_user
        plug :sync_clerk_user
      end

      pipeline :require_clerk_auth do
        plug :fetch_clerk_user
        plug :sync_clerk_user
        plug :require_authenticated_clerk_user
      end
  """

  import Plug.Conn
  import Phoenix.Controller

  use Phoenix.VerifiedRoutes,
    endpoint: CinegraphWeb.Endpoint,
    router: CinegraphWeb.Router,
    statics: CinegraphWeb.static_paths()

  alias Cinegraph.Accounts.User
  alias Cinegraph.Auth.Clerk.JWT
  alias Cinegraph.Auth.Clerk.Sync, as: ClerkSync

  require Logger

  # ============================================================================
  # Public Plugs
  # ============================================================================

  @doc """
  Verifies the Clerk JWT and assigns the raw claims to `conn.assigns.auth_user`.
  Assigns `nil` when no/invalid token is present (never halts).
  """
  def fetch_clerk_user(conn, _opts) do
    case get_clerk_token(conn) do
      nil ->
        assign(conn, :auth_user, nil)

      token ->
        case JWT.verify_token(token) do
          {:ok, claims} ->
            Logger.debug("Clerk token verified", %{clerk_id: claims["sub"]})
            assign(conn, :auth_user, claims)

          {:error, reason} ->
            Logger.debug("Clerk token verification failed: #{inspect(reason)}")
            assign(conn, :auth_user, nil)
        end
    end
  end

  @doc """
  Syncs the Clerk user to the local database and assigns the local `%User{}`
  to `conn.assigns.current_user`. Must run after `fetch_clerk_user`.
  """
  def sync_clerk_user(conn, _opts) do
    case conn.assigns[:auth_user] do
      nil ->
        assign(conn, :current_user, nil)

      claims when is_map(claims) ->
        case ClerkSync.sync_user(claims) do
          {:ok, user} ->
            conn
            |> assign(:current_user, user)
            |> put_session("current_user_id", user.id)

          {:error, reason} ->
            Logger.warning("Failed to sync Clerk user: #{inspect(reason)}")
            assign(conn, :current_user, nil)
        end

      %User{} = user ->
        conn
        |> assign(:current_user, user)
        |> put_session("current_user_id", user.id)

      _ ->
        assign(conn, :current_user, nil)
    end
  end

  @doc """
  Requires an authenticated user. Redirects to the login page if absent.
  """
  def require_authenticated_clerk_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> maybe_store_return_to()
      |> put_flash(:error, "You must log in to access this page.")
      |> redirect(to: ~p"/auth/login")
      |> halt()
    end
  end

  @doc """
  Requires an authenticated user for API requests. Returns JSON 401 instead of
  redirecting.
  """
  def require_authenticated_clerk_api_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{
        success: false,
        error: "unauthorized",
        message: "You must be logged in to access this endpoint"
      })
      |> halt()
    end
  end

  @doc """
  Redirects already-authenticated users away from auth pages.
  """
  def redirect_if_clerk_user_is_authenticated(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
      |> redirect(to: ~p"/")
      |> halt()
    else
      conn
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp get_clerk_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        token

      _ ->
        conn = fetch_cookies(conn)
        conn.cookies["__session"]
    end
  end

  defp maybe_store_return_to(conn) do
    if conn.method == "GET" do
      put_session(conn, :user_return_to, current_path(conn))
    else
      conn
    end
  end
end
