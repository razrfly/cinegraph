defmodule CinegraphWeb.Plugs.ApiAuthPlug do
  @moduledoc """
  Plug that extracts the Bearer token from the Authorization header and
  injects it into the Absinthe context for use by ApiAuth middleware.

  Add to the :api pipeline in the router so it runs before Absinthe.Plug.
  """

  @behaviour Plug

  def init(opts), do: opts

  def call(conn, _opts) do
    token =
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer " <> token | _] -> String.trim(token)
        _ -> nil
      end

    Plug.Conn.put_private(conn, :absinthe, %{context: %{auth_token: token}})
  end
end
