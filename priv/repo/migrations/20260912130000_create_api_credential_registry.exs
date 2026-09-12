defmodule Cinegraph.Repo.Migrations.CreateApiCredentialRegistry do
  use Ecto.Migration

  def change do
    create table(:api_clients) do
      add :slug, :string, null: false
      add :label, :string, null: false
      add :owner_contact, :string, null: false
      add :environment, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :scopes, {:array, :string}, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_clients, [:slug])

    create constraint(:api_clients, :api_clients_identity_not_blank,
             check:
               "btrim(slug) <> '' AND btrim(label) <> '' AND btrim(owner_contact) <> '' AND btrim(environment) <> ''"
           )

    create constraint(:api_clients, :api_clients_scopes_not_empty,
             check: "cardinality(scopes) > 0"
           )

    create constraint(:api_clients, :api_clients_scopes_allowlist,
             check: "scopes <@ ARRAY['catalog:read']::varchar[]"
           )

    create table(:api_keys) do
      add :api_client_id, references(:api_clients, on_delete: :restrict), null: false
      add :public_id, :string, null: false
      add :secret_digest, :binary, null: false
      add :label, :string, null: false
      add :created_by, :string, null: false
      add :expires_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_keys, [:public_id])
    create index(:api_keys, [:api_client_id])

    create constraint(:api_keys, :api_keys_public_id_format,
             check: "public_id ~ '^[0-9a-f]{32}$'"
           )

    create constraint(:api_keys, :api_keys_digest_length,
             check: "octet_length(secret_digest) = 32"
           )

    create constraint(:api_keys, :api_keys_identity_not_blank,
             check: "btrim(label) <> '' AND btrim(created_by) <> ''"
           )
  end
end
