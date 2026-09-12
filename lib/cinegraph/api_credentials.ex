defmodule Cinegraph.ApiCredentials do
  @moduledoc """
  Issues and verifies revocable, per-consumer catalog API credentials.

  Tokens have one exact format: `cg_<32-char-public-id>_<43-char-secret>`.
  The public ID is lowercase hexadecimal (128 random bits), making the underscore
  delimiter unambiguous. The secret is unpadded base64url (256 random bits). Only
  the SHA-256 secret digest is persisted.
  """

  import Ecto.Query

  alias Cinegraph.ApiCredentials.{ApiClient, ApiKey, Principal}
  alias Cinegraph.Repo

  @prefix "cg_"
  @public_id_length 32
  @secret_length 43
  @token_length 3 + @public_id_length + 1 + @secret_length
  @catalog_scope "catalog:read"

  @type auth_error ::
          :missing
          | :malformed
          | :unknown
          | :wrong_secret
          | :revoked
          | :expired
          | :disabled
          | :invalid_scope
          | :registry_unavailable

  def create_client(attrs), do: %ApiClient{} |> ApiClient.changeset(attrs) |> Repo.insert()

  def list_clients do
    Repo.all(from c in ApiClient, order_by: [asc: c.slug])
  end

  def get_client_by_slug(slug), do: Repo.get_by(ApiClient, slug: slug)

  def disable_client(slug) do
    case get_client_by_slug(slug) do
      nil -> {:error, :not_found}
      client -> client |> ApiClient.changeset(%{enabled: false}) |> Repo.update()
    end
  end

  def issue_key(client_or_slug, attrs) do
    with true <- explicit_expiry?(attrs) || {:error, :expiry_choice_required},
         {:ok, client} <- resolve_client(client_or_slug),
         true <- client.enabled || {:error, :client_disabled} do
      do_issue_key(client, attrs, 3)
    end
  end

  def rotate_key(client_or_slug, attrs), do: issue_key(client_or_slug, attrs)

  def list_keys(client_or_slug) do
    with {:ok, client} <- resolve_client(client_or_slug) do
      {:ok,
       Repo.all(
         from k in ApiKey,
           where: k.api_client_id == ^client.id,
           order_by: [desc: k.inserted_at]
       )}
    end
  end

  def revoke_key(public_id, now \\ DateTime.utc_now()) do
    now = truncate(now)

    case Repo.get_by(ApiKey, public_id: public_id) do
      nil -> {:error, :not_found}
      %ApiKey{revoked_at: revoked_at} = key when not is_nil(revoked_at) -> {:ok, key}
      key -> key |> ApiKey.changeset(%{revoked_at: now}) |> Repo.update()
    end
  end

  def registry_token?(token) when is_binary(token), do: String.starts_with?(token, @prefix)
  def registry_token?(_), do: false

  def parse_token(token) when is_binary(token) and byte_size(token) == @token_length do
    case String.split(token, "_", parts: 3) do
      ["cg", public_id, secret]
      when byte_size(public_id) == @public_id_length and byte_size(secret) == @secret_length ->
        if hex?(public_id) and canonical_secret?(secret),
          do: {:ok, public_id, secret},
          else: {:error, :malformed}

      _ ->
        {:error, :malformed}
    end
  end

  def parse_token(_), do: {:error, :malformed}

  def authenticate(token, opts \\ [])
  def authenticate(nil, _opts), do: emit_auth({:error, :missing}, nil)

  def authenticate(token, opts) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> truncate()
    repo = Keyword.get(opts, :repo, Repo)

    result =
      with {:ok, public_id, secret} <- parse_token(token),
           {:ok, key, client} <- lookup_key(repo, public_id),
           :ok <- verify_secret(key, secret),
           :ok <- verify_key_policy(key, client, now),
           :ok <- verify_scopes(client.scopes) do
        {:ok,
         %Principal{
           client_id: client.id,
           key_id: key.id,
           client_slug: client.slug,
           scopes: client.scopes,
           kind: :registry
         }}
      end

    emit_auth(result, public_id_from(result, token))
  rescue
    _ -> emit_auth({:error, :registry_unavailable}, nil)
  catch
    :exit, _ -> emit_auth({:error, :registry_unavailable}, nil)
  end

  def authorized?(%Principal{scopes: scopes}, @catalog_scope), do: @catalog_scope in scopes
  def authorized?(_, _), do: false

  defp do_issue_key(client, attrs, attempts_left) do
    public_id = random_hex(16)
    secret = random_base64url(32)
    token = "#{@prefix}#{public_id}_#{secret}"

    attrs =
      attrs
      |> Map.new()
      |> Map.merge(%{
        api_client_id: client.id,
        public_id: public_id,
        secret_digest: digest(secret)
      })

    case %ApiKey{} |> ApiKey.changeset(attrs) |> Repo.insert() do
      {:ok, key} ->
        {:ok, key, token}

      {:error, %Ecto.Changeset{errors: [public_id: _]}} when attempts_left > 1 ->
        do_issue_key(client, attrs, attempts_left - 1)

      error ->
        error
    end
  end

  defp resolve_client(%ApiClient{} = client), do: {:ok, client}

  defp resolve_client(slug) when is_binary(slug) do
    case get_client_by_slug(slug) do
      nil -> {:error, :client_not_found}
      client -> {:ok, client}
    end
  end

  defp explicit_expiry?(attrs) when is_map(attrs) do
    Map.has_key?(attrs, :expires_at) or Map.has_key?(attrs, "expires_at")
  end

  defp explicit_expiry?(attrs) when is_list(attrs), do: Keyword.has_key?(attrs, :expires_at)
  defp explicit_expiry?(_), do: false

  defp lookup_key(repo, public_id) do
    query =
      from k in ApiKey,
        join: c in assoc(k, :api_client),
        where: k.public_id == ^public_id,
        select: {k, c}

    case repo.one(query) do
      nil -> {:error, :unknown}
      {key, client} -> {:ok, key, client}
    end
  end

  defp verify_secret(key, secret) do
    candidate = digest(secret)

    if Plug.Crypto.secure_compare(candidate, key.secret_digest),
      do: :ok,
      else: {:error, :wrong_secret}
  end

  defp verify_key_policy(%ApiKey{revoked_at: revoked_at}, _client, _now)
       when not is_nil(revoked_at),
       do: {:error, :revoked}

  defp verify_key_policy(_key, %ApiClient{enabled: false}, _now), do: {:error, :disabled}

  defp verify_key_policy(%ApiKey{expires_at: expires_at}, _client, now)
       when not is_nil(expires_at) do
    if DateTime.compare(now, expires_at) == :lt, do: :ok, else: {:error, :expired}
  end

  defp verify_key_policy(_key, _client, _now), do: :ok

  defp verify_scopes(scopes) do
    if is_list(scopes) and scopes != [] and Enum.all?(scopes, &(&1 == @catalog_scope)),
      do: :ok,
      else: {:error, :invalid_scope}
  end

  defp random_hex(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp random_base64url(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp digest(secret), do: :crypto.hash(:sha256, secret)
  defp hex?(value), do: Regex.match?(~r/\A[0-9a-f]+\z/, value)
  defp base64url?(value), do: Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value)

  defp canonical_secret?(secret) do
    base64url?(secret) and
      case Base.url_decode64(secret, padding: false) do
        {:ok, bytes} ->
          byte_size(bytes) == 32 and Base.url_encode64(bytes, padding: false) == secret

        :error ->
          false
      end
  end

  defp truncate(%DateTime{} = dt), do: DateTime.truncate(dt, :microsecond)

  defp public_id_from({:ok, %Principal{key_id: key_id}}, _token), do: key_id

  defp public_id_from(_result, token) do
    case parse_token(token) do
      {:ok, public_id, _secret} -> public_id
      _ -> nil
    end
  end

  defp emit_auth(result, identifier) do
    {outcome, metadata} =
      case result do
        {:ok, %Principal{} = principal} ->
          {:ok,
           %{
             outcome: :ok,
             auth_kind: principal.kind,
             client_id: principal.client_id,
             key_id: principal.key_id,
             client_slug: principal.client_slug
           }}

        {:error, reason} ->
          {reason,
           %{
             outcome: reason,
             auth_kind: :registry,
             client_id: nil,
             key_id: nil,
             public_id: identifier,
             client_slug: nil
           }}
      end

    :telemetry.execute([:cinegraph, :api_auth, :stop], %{count: 1}, metadata)
    if outcome == :ok, do: result, else: {:error, outcome}
  end
end
