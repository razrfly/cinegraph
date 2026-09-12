defmodule Mix.Tasks.Cinegraph.Prod.ApiCredentials do
  use Mix.Task

  alias Cinegraph.ProdRpc

  @shortdoc "Manage production API credentials through Kamal"

  @moduledoc """
  Manages the production API credential registry through the project's
  authenticated Kamal connection.

      mix cinegraph.prod.api_credentials client-create --slug wordhoard-preview \
        --label "Wordhoard preview" --owner-contact ops@example.com --environment preview
      mix cinegraph.prod.api_credentials client-list
      mix cinegraph.prod.api_credentials client-disable --slug wordhoard-preview
      mix cinegraph.prod.api_credentials key-issue --client wordhoard-preview \
        --label initial --created-by operator@example.com --no-expiry
      mix cinegraph.prod.api_credentials key-list --client wordhoard-preview
      mix cinegraph.prod.api_credentials key-revoke --public-id PUBLIC_ID
      mix cinegraph.prod.api_credentials key-rotate --client wordhoard-preview \
        --old-public-id PUBLIC_ID --label rotation \
        --created-by operator@example.com --no-expiry

  Add `--json` for compact machine-readable output. Plaintext key material is
  returned only by `key-issue` and `key-rotate`.
  """

  @switches [
    slug: :string,
    label: :string,
    owner_contact: :string,
    environment: :string,
    client: :string,
    created_by: :string,
    expires_at: :string,
    no_expiry: :boolean,
    public_id: :string,
    old_public_id: :string,
    json: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    {command, params} = command!(positional, Map.new(opts))

    case ProdRpc.eval_json(build_expression(command, params)) do
      {:ok, %{"ok" => false} = result} ->
        ProdRpc.print(result, opts)
        Mix.raise("production credential operation failed")

      {:ok, result} ->
        ProdRpc.print(result, opts)

      {:error, reason} ->
        ProdRpc.print_error(reason)
    end
  end

  @doc false
  def build_expression(command, params) when is_binary(command) and is_map(params) do
    payload = params |> Jason.encode!() |> Base.encode64()

    "params = Jason.decode!(Base.decode64!(#{inspect(payload)}))\n" <>
      "result = Cinegraph.Release.api_credential_command(#{inspect(command)}, params)\n" <>
      "IO.puts(Jason.encode!(result))"
  end

  defp command!(["client-create"], opts) do
    {"client-create",
     %{
       "slug" => required!(opts, :slug),
       "label" => required!(opts, :label),
       "owner_contact" => required!(opts, :owner_contact),
       "environment" => required!(opts, :environment)
     }}
  end

  defp command!(["client-list"], _opts), do: {"client-list", %{}}

  defp command!(["client-disable"], opts) do
    {"client-disable", %{"slug" => required!(opts, :slug)}}
  end

  defp command!(["key-issue"], opts) do
    {"key-issue", key_params(opts)}
  end

  defp command!(["key-rotate"], opts) do
    {"key-rotate", Map.put(key_params(opts), "old_public_id", required!(opts, :old_public_id))}
  end

  defp command!(["key-list"], opts) do
    {"key-list", %{"client" => required!(opts, :client)}}
  end

  defp command!(["key-revoke"], opts) do
    {"key-revoke", %{"public_id" => required!(opts, :public_id)}}
  end

  defp command!(_positional, _opts) do
    Mix.raise("unknown or malformed command; run `mix help cinegraph.prod.api_credentials`")
  end

  defp key_params(opts) do
    %{
      "client" => required!(opts, :client),
      "label" => required!(opts, :label),
      "created_by" => required!(opts, :created_by),
      "expires_at" => expiry!(opts)
    }
  end

  defp expiry!(%{no_expiry: true} = opts) do
    if Map.has_key?(opts, :expires_at),
      do: Mix.raise("choose --expires-at or --no-expiry, not both")

    nil
  end

  defp expiry!(%{expires_at: value}) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> DateTime.to_iso8601(datetime)
      _ -> Mix.raise("--expires-at must be an ISO 8601 UTC timestamp")
    end
  end

  defp expiry!(_), do: Mix.raise("choose an explicit --expires-at or --no-expiry")

  defp required!(opts, key) do
    case Map.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      _ -> Mix.raise("missing --#{key |> Atom.to_string() |> String.replace("_", "-")}")
    end
  end
end
