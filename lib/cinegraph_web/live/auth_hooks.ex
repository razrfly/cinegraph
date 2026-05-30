defmodule CinegraphWeb.Live.AuthHooks do
  @moduledoc """
  Authentication `on_mount` hooks for Phoenix LiveView.

  Assigns `@current_user` (a local `%Cinegraph.Accounts.User{}` or `nil`).

  ## CDN-safe auth

  Public pages are cached the same for everyone, so the Phoenix session cookie
  may be stripped by the CDN. We therefore resolve the user from two sources:

  1. `session["current_user_id"]` (set by `ClerkAuthPlug` on the initial request)
  2. `connect_params["clerk_token"]` — a fresh Clerk JWT passed by the client when
     the LiveView WebSocket connects (survives CDN caching)

  ## Usage

      on_mount {CinegraphWeb.Live.AuthHooks, :assign_auth_user}
      on_mount {CinegraphWeb.Live.AuthHooks, :require_authenticated_user}
  """

  import Phoenix.Component
  import Phoenix.LiveView

  use Phoenix.VerifiedRoutes,
    endpoint: CinegraphWeb.Endpoint,
    router: CinegraphWeb.Router,
    statics: CinegraphWeb.static_paths()

  alias Cinegraph.Accounts
  alias Cinegraph.Auth.Clerk.JWT, as: ClerkJWT
  alias Cinegraph.Auth.Clerk.Sync, as: ClerkSync

  require Logger

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:assign_auth_user, _params, session, socket) do
    {:cont, assign_current_user(socket, session)}
  end

  def on_mount(:require_authenticated_user, _params, session, socket) do
    socket = assign_current_user(socket, session)

    cond do
      socket.assigns[:current_user] ->
        {:cont, socket}

      # Static render (not yet connected): connect_params aren't available, so we
      # can't see the Clerk token. Let the page load; re-check on WebSocket connect.
      not connected?(socket) ->
        {:cont, socket}

      true ->
        {:halt,
         socket
         |> maybe_put_flash(:error, "You must log in to access this page.")
         |> redirect(to: ~p"/auth/login")}
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp assign_current_user(socket, session) do
    assign_new(socket, :current_user, fn ->
      user_from_session(session) || user_from_connect_params(socket)
    end)
  end

  defp user_from_session(session) do
    case session["current_user_id"] do
      id when is_integer(id) -> Accounts.get_user(id)
      _ -> nil
    end
  end

  # Resolve the user from a Clerk JWT passed via LiveSocket connect_params.
  # Only available once the socket is connected (not during static render).
  defp user_from_connect_params(socket) do
    if connected?(socket) do
      case get_connect_params(socket) do
        %{"clerk_token" => token} when is_binary(token) and token != "" ->
          verify_and_get_user(token)

        _ ->
          nil
      end
    else
      nil
    end
  end

  defp verify_and_get_user(token) do
    case ClerkJWT.verify_token(token) do
      {:ok, claims} ->
        case ClerkSync.get_user(claims) do
          {:ok, user} ->
            user

          {:error, :not_found} ->
            case ClerkSync.sync_user(claims) do
              {:ok, user} -> user
              {:error, _reason} -> nil
            end

          {:error, _reason} ->
            nil
        end

      {:error, reason} ->
        Logger.debug("Clerk token verification failed: #{inspect(reason)}")
        nil
    end
  end

  defp maybe_put_flash(socket, key, message) do
    case socket.assigns.flash[key] do
      nil -> put_flash(socket, key, message)
      _existing -> socket
    end
  end
end
