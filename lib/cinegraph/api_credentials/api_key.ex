defmodule Cinegraph.ApiCredentials.ApiKey do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias Cinegraph.ApiCredentials.ApiClient

  schema "api_keys" do
    field :public_id, :string
    field :secret_digest, :binary
    field :label, :string
    field :created_by, :string
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec

    belongs_to :api_client, ApiClient

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(key, attrs) do
    key
    |> cast(attrs, [
      :api_client_id,
      :public_id,
      :secret_digest,
      :label,
      :created_by,
      :expires_at,
      :revoked_at,
      :last_used_at
    ])
    |> update_change(:label, &trim/1)
    |> update_change(:created_by, &trim/1)
    |> validate_required([:api_client_id, :public_id, :secret_digest, :label, :created_by])
    |> validate_length(:public_id, is: 32)
    |> validate_format(:public_id, ~r/\A[0-9a-f]{32}\z/)
    |> validate_digest()
    |> validate_length(:label, max: 160)
    |> validate_length(:created_by, max: 320)
    |> unique_constraint(:public_id)
    |> foreign_key_constraint(:api_client_id)
    |> check_constraint(:public_id, name: :api_keys_public_id_format)
    |> check_constraint(:secret_digest, name: :api_keys_digest_length)
    |> check_constraint(:label, name: :api_keys_identity_not_blank)
  end

  defp validate_digest(changeset) do
    validate_change(changeset, :secret_digest, fn :secret_digest, digest ->
      if is_binary(digest) and byte_size(digest) == 32,
        do: [],
        else: [secret_digest: "must be a 32-byte digest"]
    end)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
