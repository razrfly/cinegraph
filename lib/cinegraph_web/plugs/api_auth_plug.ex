defmodule CinegraphWeb.Plugs.ApiAuthPlug do
  @moduledoc """
  Plug that extracts the Bearer token from the Authorization header and
  injects it into the Absinthe context for use by ApiAuth middleware.

  Used as the `context:` function on Absinthe.Plug forward routes.
  """

  @doc """
  Build the Absinthe context map from a Plug.Conn.
  Extracts `Authorization: Bearer <token>` and exposes it as `auth_token`.
  """
  def build_context(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> %{auth_token: String.trim(token)}
      _ -> %{}
    end
  end
end
