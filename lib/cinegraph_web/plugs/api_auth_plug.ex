defmodule CinegraphWeb.Plugs.ApiAuthPlug do
  @moduledoc """
  Plug that extracts the Bearer token from the Authorization header and builds
  the Absinthe context. Add to the :api pipeline so it runs before Absinthe.Plug.

  Supports two independent, coexisting auth modes (#838):

    * **Shared API key** — the raw token is placed in `context.auth_token` and
      compared against `CINEGRAPH_API_KEY` by `CinegraphWeb.Middleware.ApiAuth`.
      This is the existing read-only access path (unchanged).

    * **Clerk user bearer** — if the token verifies as a Clerk JWT, the synced
      local `%Cinegraph.Accounts.User{}` is placed in `context.current_user`.
      User-specific fields gate on this via `CinegraphWeb.Middleware.RequireUser`.
  """

  @behaviour Plug

  alias Cinegraph.Auth.Clerk.JWT
  alias Cinegraph.Auth.Clerk.Sync, as: ClerkSync

  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    token =
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer " <> token | _] -> String.trim(token)
        _ -> nil
      end

    context =
      %{auth_token: token}
      |> maybe_put_current_user(token)

    Plug.Conn.put_private(conn, :absinthe, %{context: context})
  end

  # Attempt Clerk JWT verification. On success, sync + attach the local user.
  # Failure is silent — the shared API-key path still applies to `auth_token`.
  defp maybe_put_current_user(context, nil), do: context

  defp maybe_put_current_user(context, token) do
    with {:ok, claims} <- JWT.verify_token(token),
         {:ok, user} <- ClerkSync.sync_user(claims) do
      context
      |> Map.put(:current_user, user)
      |> Map.put(:clerk_claims, claims)
    else
      _ -> context
    end
  end
end
