defmodule Cinegraph.Accounts do
  @moduledoc """
  Context for local user accounts (#838).

  Users authenticate through Clerk; this context owns the canonical local
  `users` records. `Cinegraph.Auth.Clerk.Sync` calls into here to find-or-create
  users from verified Clerk JWT claims.
  """

  import Ecto.Query, warn: false

  alias Cinegraph.Repo
  alias Cinegraph.Accounts.User

  @doc """
  Gets a user by primary key. Returns `nil` if not found.
  """
  def get_user(id) when is_integer(id), do: Repo.get(User, id)
  def get_user(_), do: nil

  @doc """
  Gets a user by primary key. Raises if not found.
  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Gets a user by email (case-insensitive via the `citext` column).
  Returns `nil` if not found or given a non-binary.
  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: String.downcase(email))
  end

  def get_user_by_email(_), do: nil

  @doc """
  Creates a user.
  """
  def create_user(attrs \\ %{}) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a user.
  """
  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end
end
