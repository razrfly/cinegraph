defmodule CinegraphWeb.Middleware.RequireUser do
  @moduledoc """
  Absinthe middleware that requires an authenticated Clerk user (#838).

  Reads `context.current_user` (populated by `CinegraphWeb.Plugs.ApiAuthPlug`
  when a valid Clerk bearer JWT is presented) and errors otherwise.

  Use on user-specific fields/mutations:

      field :viewer, :user do
        middleware CinegraphWeb.Middleware.RequireUser
        resolve &MyResolver.viewer/3
      end

  This is independent of `CinegraphWeb.Middleware.ApiAuth` (the shared read-only
  API key) — the shared key does NOT grant user-specific access.
  """

  @behaviour Absinthe.Middleware

  def call(resolution, _config) do
    case resolution.context do
      %{current_user: %Cinegraph.Accounts.User{}} ->
        resolution

      _ ->
        Absinthe.Resolution.put_result(resolution, {:error, "unauthorized"})
    end
  end
end
