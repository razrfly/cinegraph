defmodule CinegraphWeb.Plugs.ApiAuthPlug do
  @moduledoc """
  Authenticates an application credential once per HTTP request and builds the
  Absinthe context. Application and Clerk user identities remain independent.

  Registry-format credentials are sent exclusively to the registry verifier.
  Non-JWT, non-registry tokens are sent exclusively to the time-bounded legacy
  verifier during migration. Neither path attempts Clerk verification.
  """

  @behaviour Plug

  alias Cinegraph.ApiCredentials
  alias Cinegraph.ApiCredentials.{Legacy, Principal}
  alias Cinegraph.Auth.Clerk.JWT
  alias Cinegraph.Auth.Clerk.Sync, as: ClerkSync

  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    Logger.metadata(
      api_client_id: nil,
      api_key_id: nil,
      api_client_slug: nil,
      api_auth_kind: nil
    )

    token = bearer_token(conn)
    context = authenticate(token)
    Plug.Conn.put_private(conn, :absinthe, %{context: context})
  end

  defp authenticate(nil) do
    if local_bypass?() do
      emit_outcome(:local_bypass, :local_bypass, "local", "local", "local-development")

      %{api_auth_bypass: true, api_auth_outcome: :local_bypass}
    else
      emit_outcome(:missing, :none)
      %{api_auth_outcome: :missing}
    end
  end

  defp authenticate(token) do
    cond do
      ApiCredentials.registry_token?(token) ->
        service_context(ApiCredentials.authenticate(token))

      Legacy.configured_token?(token) ->
        service_context(Legacy.authenticate(token))

      jwt_shaped?(token) ->
        clerk_context(token)

      true ->
        service_context(Legacy.authenticate(token))
    end
  end

  defp service_context({:ok, %Principal{} = principal}) do
    Logger.metadata(
      api_client_id: principal.client_id,
      api_key_id: principal.key_id,
      api_client_slug: principal.client_slug,
      api_auth_kind: principal.kind
    )

    %{service_principal: principal, api_auth_outcome: :ok}
  end

  defp service_context({:error, reason}), do: %{api_auth_outcome: reason}

  defp clerk_context(token) do
    with {:ok, claims} <- JWT.verify_token(token),
         {:ok, user} <- ClerkSync.sync_user(claims) do
      emit_outcome(:clerk_authenticated, :clerk)
      %{current_user: user, clerk_claims: claims, api_auth_outcome: :clerk_authenticated}
    else
      _ ->
        emit_outcome(:invalid_user_token, :clerk)
        %{api_auth_outcome: :invalid_user_token}
    end
  end

  defp emit_outcome(outcome, kind, client_id \\ nil, key_id \\ nil, slug \\ nil) do
    :telemetry.execute(
      [:cinegraph, :api_auth, :stop],
      %{count: 1},
      %{
        outcome: outcome,
        auth_kind: kind,
        client_id: client_id,
        key_id: key_id,
        client_slug: slug
      }
    )
  end

  defp bearer_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> String.trim(token)
      _ -> nil
    end
  end

  defp jwt_shaped?(token) do
    case String.split(token, ".", parts: 4) do
      [header, payload, signature] -> header != "" and payload != "" and signature != ""
      _ -> false
    end
  end

  defp local_bypass? do
    Application.get_env(:cinegraph, :environment) in [:dev, :test] and
      Application.get_env(:cinegraph, :api_auth_local_bypass, false) == true
  end
end
