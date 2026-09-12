defmodule CinegraphWeb.Middleware.ApiAuth do
  @moduledoc """
  Authorizes an already authenticated application principal for catalog reads.

  Authentication and its database lookup happen in `ApiAuthPlug`, once per HTTP
  request. A Clerk `current_user` alone deliberately does not satisfy this gate.
  """

  @behaviour Absinthe.Middleware

  alias Cinegraph.ApiCredentials

  def call(%{context: %{api_auth_bypass: true}} = resolution, "catalog:read"), do: resolution

  def call(%{context: %{service_principal: principal}} = resolution, scope)
      when is_binary(scope) do
    if ApiCredentials.authorized?(principal, scope) do
      :telemetry.execute(
        [:cinegraph, :api_auth, :catalog_field],
        %{request_cost: 1},
        %{
          client_id: principal.client_id,
          key_id: principal.key_id,
          client_slug: principal.client_slug,
          auth_kind: principal.kind,
          scope: scope
        }
      )

      resolution
    else
      unauthorized(resolution)
    end
  end

  def call(resolution, _), do: unauthorized(resolution)

  defp unauthorized(resolution) do
    Absinthe.Resolution.put_result(resolution, {:error, "unauthorized"})
  end
end
