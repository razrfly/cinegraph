defmodule CinegraphWeb.Auth.ClerkAuthController do
  @moduledoc """
  Controller for Clerk-based authentication routes.

  Clerk handles authentication through its frontend components, so this
  controller mostly renders pages that mount those components and manages
  post-authentication redirects + logout.
  """
  use CinegraphWeb, :controller
  require Logger

  alias Cinegraph.Auth.AuthProvider

  # Render auth pages with the V2 chrome (mist palette + n_top_nav) used by the
  # rest of the site, not the legacy root layout. Mirrors the V2 LiveView setup
  # (root_layout: :v2_root, layout: false).
  plug :put_root_layout, html: {CinegraphWeb.Layouts, :v2_root}
  plug :put_layout, false
  plug :check_clerk_enabled

  @doc """
  Show the Clerk sign-in page (mounts Clerk's SignIn component).
  """
  def login(conn, params) do
    conn
    |> assign(:return_to, get_safe_return_to(params["return_to"]))
    |> render(:clerk_login)
  end

  @doc """
  Show the Clerk sign-up page (mounts Clerk's SignUp component).
  """
  def register(conn, params) do
    conn
    |> maybe_store_return_to(params["return_to"])
    |> assign(:return_to, get_safe_return_to(params["return_to"]))
    |> render(:clerk_register)
  end

  @doc """
  Handle Clerk logout: clear the server session and Clerk's cookies.
  """
  def logout(conn, _params) do
    cookie_opts = [
      path: "/",
      http_only: true,
      secure: https?(),
      same_site: "Lax"
    ]

    conn
    |> configure_session(drop: true)
    |> delete_resp_cookie("__session", cookie_opts)
    |> delete_resp_cookie("__client_uat", cookie_opts)
    |> put_flash(:info, "You have been logged out")
    |> redirect(to: ~p"/")
  end

  @doc """
  Handle the post-authentication callback from Clerk.
  """
  def callback(conn, params) do
    Logger.debug("Clerk auth callback received: #{inspect(Map.keys(params))}")

    return_to = get_safe_return_to(params["return_to"]) || get_session(conn, :user_return_to)

    conn = delete_session(conn, :user_return_to)

    redirect(conn, to: return_to || ~p"/")
  end

  @doc """
  Clerk user profile page (mounts Clerk's UserProfile component).
  """
  def profile(conn, _params) do
    render(conn, :clerk_profile)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp check_clerk_enabled(conn, _opts) do
    if AuthProvider.clerk_enabled?() do
      conn
    else
      conn
      |> put_flash(:error, "Clerk authentication is not enabled.")
      |> redirect(to: ~p"/")
      |> halt()
    end
  end

  defp maybe_store_return_to(conn, return_to) when is_binary(return_to) do
    if valid_internal_url?(return_to) do
      put_session(conn, :user_return_to, return_to)
    else
      Logger.warning("Invalid return URL rejected: #{return_to}")
      conn
    end
  end

  defp maybe_store_return_to(conn, _), do: conn

  # Validate return_to is a safe internal URL (prevents open-redirect attacks).
  defp get_safe_return_to(nil), do: nil
  defp get_safe_return_to(""), do: nil

  defp get_safe_return_to(url) when is_binary(url) do
    if valid_internal_url?(url), do: url, else: nil
  end

  defp get_safe_return_to(_), do: nil

  defp valid_internal_url?(url) when is_binary(url) do
    if String.starts_with?(url, "/") do
      not String.contains?(url, "//")
    else
      case URI.parse(url) do
        %URI{host: nil} ->
          String.starts_with?(url, "/")

        %URI{host: host, scheme: scheme} when scheme in ["http", "https"] ->
          app_host = CinegraphWeb.Endpoint.host()
          host == app_host || (host == "localhost" && app_host == "localhost")

        _ ->
          false
      end
    end
  rescue
    _ -> false
  end

  defp valid_internal_url?(_), do: false

  defp https? do
    case CinegraphWeb.Endpoint.config(:url) do
      url when is_list(url) -> Keyword.get(url, :scheme) == "https"
      _ -> false
    end
  end
end
