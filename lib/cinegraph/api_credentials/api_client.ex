defmodule Cinegraph.ApiCredentials.ApiClient do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias Cinegraph.ApiCredentials.ApiKey

  @allowed_scopes ["catalog:read"]

  schema "api_clients" do
    field :slug, :string
    field :label, :string
    field :owner_contact, :string
    field :environment, :string
    field :enabled, :boolean, default: true
    field :scopes, {:array, :string}, default: ["catalog:read"]

    has_many :api_keys, ApiKey

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(client, attrs) do
    client
    |> cast(attrs, [:slug, :label, :owner_contact, :environment, :enabled, :scopes])
    |> update_change(:slug, &trim/1)
    |> update_change(:label, &trim/1)
    |> update_change(:owner_contact, &trim/1)
    |> update_change(:environment, &trim/1)
    |> validate_required([:slug, :label, :owner_contact, :environment, :enabled, :scopes])
    |> validate_format(:slug, ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/,
      message: "must be lowercase letters, numbers, and single hyphens"
    )
    |> validate_length(:slug, max: 80)
    |> validate_length(:label, max: 160)
    |> validate_length(:owner_contact, max: 320)
    |> validate_length(:environment, max: 80)
    |> validate_scopes()
    |> unique_constraint(:slug)
    |> check_constraint(:slug, name: :api_clients_identity_not_blank)
    |> check_constraint(:scopes, name: :api_clients_scopes_not_empty)
    |> check_constraint(:scopes, name: :api_clients_scopes_allowlist)
  end

  defp validate_scopes(changeset) do
    validate_change(changeset, :scopes, fn :scopes, scopes ->
      validate_scope_list(scopes)
    end)
  end

  defp validate_scope_list(scopes) when is_list(scopes) do
    unknown = scopes -- @allowed_scopes

    cond do
      scopes == [] ->
        [scopes: "must not be empty"]

      Enum.uniq(scopes) != scopes ->
        [scopes: "must not contain duplicates"]

      unknown != [] ->
        [scopes: "contains unknown scopes: #{Enum.join(unknown, ", ")}"]

      true ->
        []
    end
  end

  defp validate_scope_list(_), do: []
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
