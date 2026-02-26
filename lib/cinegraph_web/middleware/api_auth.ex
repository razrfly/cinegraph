defmodule CinegraphWeb.Middleware.ApiAuth do
  @moduledoc """
  Absinthe middleware that validates Bearer token authentication.

  Reads the auth token from the Absinthe context (populated by
  CinegraphWeb.Plugs.ApiAuthPlug at the connection level) and compares
  it against the configured CINEGRAPH_API_KEY.

  If CINEGRAPH_API_KEY is not set, auth is bypassed (dev convenience).
  """

  @behaviour Absinthe.Middleware

  def call(resolution, _) do
    case Application.get_env(:cinegraph, :api_key) do
      nil ->
        # No key configured — skip auth (dev convenience)
        resolution

      expected_key ->
        case resolution.context do
          %{auth_token: ^expected_key} ->
            resolution

          _ ->
            resolution
            |> Absinthe.Resolution.put_result({:error, "unauthorized"})
        end
    end
  end
end
