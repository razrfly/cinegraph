defmodule Cinegraph.Accounts.User do
  @moduledoc """
  A local Cinegraph user account.

  Authentication is owned by Clerk; this record is the canonical *application*
  user. The integer `id` is pushed to Clerk as `external_id` and returned in the
  JWT `userId` claim (see `Cinegraph.Auth.Clerk.Sync`). There is intentionally no
  `clerk_user_id` column — `id` is the single source of truth for identity.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "users" do
    field :email, :string
    field :name, :string
    field :avatar_url, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  # Mirrors the sister project's (eventasaurus) battle-tested user-account regex
  # — "@ sign and no spaces" — but with \A/\z (not ^/$) so a trailing newline
  # like "a@b.com\n" can't sneak through.
  @email_regex ~r/\A[^\s]+@[^\s]+\z/

  @doc """
  Changeset for creating/updating a user.
  """
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :avatar_url, :metadata])
    |> validate_required([:email])
    |> validate_format(:email, @email_regex, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 320)
    |> update_change(:email, &String.downcase/1)
    |> unique_constraint(:email)
  end
end
