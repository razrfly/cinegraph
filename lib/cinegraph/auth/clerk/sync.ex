defmodule Cinegraph.Auth.Clerk.Sync do
  @moduledoc """
  Synchronizes Clerk authentication users with our local database.

  This module handles creating or finding local `User` records when users
  authenticate through Clerk.

  ## How It Works

  Our `users.id` (integer primary key) is the canonical identifier.
  Clerk stores this as `external_id`, and JWT claims include it as `userId`.

  1. Look up users by their integer ID from `claims["userId"]`
  2. Fall back to email lookup (for new Clerk signups before external_id syncs)
  3. Create new users if they don't exist
  4. Sync the new local `users.id` back to Clerk as `external_id`

  ## Usage

      case Sync.sync_user(clerk_claims) do
        {:ok, user} -> # %User{}
        {:error, reason} -> # Error handling
      end
  """

  alias Cinegraph.Accounts
  alias Cinegraph.Auth.Clerk.Client

  require Logger

  @doc """
  Synchronizes a Clerk user with our local database.

  Takes the verified JWT claims from Clerk and ensures a corresponding
  `User` record exists in our database.

  ## Claims Structure
    - "sub": Clerk user ID (e.g., "user_abc123")
    - "userId": Our users.id (integer, stored as Clerk's external_id)
    - "email": User's email address
    - "first_name", "last_name": User's name components
    - "image_url": User's avatar URL (optional)

  ## Returns
    - {:ok, %User{}} on success
    - {:error, reason} on failure
  """
  def sync_user(claims, opts \\ [])

  def sync_user(claims, opts) when is_map(claims) do
    user_id = parse_user_id(claims["userId"])
    clerk_id = claims["sub"]
    email = claims["email"]

    Logger.debug("Starting Clerk user sync", %{
      clerk_id: clerk_id,
      user_id: user_id,
      has_email: not is_nil(email)
    })

    find_or_create_user(user_id, clerk_id, email, claims, opts)
  end

  def sync_user(_, _), do: {:error, :invalid_claims}

  @doc """
  Gets a user from the local database based on Clerk claims.

  Read-only — does not create or update users.

  ## Returns
    - {:ok, %User{}} if user is found
    - {:error, :not_found} if no matching user
  """
  def get_user(claims) when is_map(claims) do
    user_id = parse_user_id(claims["userId"])
    email = claims["email"]

    cond do
      is_integer(user_id) ->
        case Accounts.get_user(user_id) do
          nil -> {:error, :not_found}
          user -> {:ok, user}
        end

      not is_nil(email) ->
        case Accounts.get_user_by_email(email) do
          nil -> {:error, :not_found}
          user -> {:ok, user}
        end

      true ->
        {:error, :not_found}
    end
  end

  def get_user(_), do: {:error, :invalid_claims}

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp find_or_create_user(user_id, clerk_id, email, claims, opts) do
    cond do
      # Strategy 1: Look up by integer ID (external_id already synced)
      is_integer(user_id) ->
        case Accounts.get_user(user_id) do
          nil ->
            Logger.warning("User ID from claims not found in database", %{user_id: user_id})
            find_by_email_or_create(clerk_id, email, claims, opts)

          user ->
            Logger.debug("Found user by ID", %{user_id: user.id})
            maybe_update_user(user, claims, opts)
        end

      # Strategy 2: New Clerk signup - no userId claim yet
      true ->
        find_by_email_or_create(clerk_id, email, claims, opts)
    end
  end

  defp find_by_email_or_create(clerk_id, email, claims, opts) do
    if email do
      case Accounts.get_user_by_email(email) do
        nil ->
          create_user_from_clerk(clerk_id, email, claims, opts)

        user ->
          Logger.info("Found user by email", %{user_id: user.id})
          maybe_update_user(user, claims, opts)
      end
    else
      # No email in claims - try to fetch from Clerk API
      fetch_email_and_create(clerk_id, claims, opts)
    end
  end

  defp fetch_email_and_create(clerk_id, claims, opts) do
    # Client.get_user/1 raises if Clerk isn't configured (no secret_key). Guard
    # so a claims set lacking an email returns a clean error instead of crashing.
    if not clerk_configured?() do
      Logger.error("Cannot fetch Clerk user email — Clerk is not configured", %{
        clerk_id: clerk_id
      })

      {:error, :clerk_unconfigured}
    else
      do_fetch_email_and_create(clerk_id, claims, opts)
    end
  end

  defp do_fetch_email_and_create(clerk_id, claims, opts) do
    case Client.get_user(clerk_id) do
      {:ok, clerk_user} ->
        email = extract_email_from_clerk_user(clerk_user)

        if email do
          find_by_email_or_create(clerk_id, email, claims, opts)
        else
          Logger.error("Clerk user has no email address", %{clerk_id: clerk_id})
          {:error, :no_email}
        end

      {:error, reason} ->
        Logger.error("Failed to fetch Clerk user", %{
          clerk_id: clerk_id,
          reason: inspect(reason)
        })

        {:error, :clerk_api_error}
    end
  end

  defp create_user_from_clerk(clerk_id, email, claims, _opts) do
    user_params = %{
      email: email,
      name: extract_name_from_claims(claims),
      avatar_url: claims["image_url"]
    }

    Logger.info("Creating new user from Clerk", %{
      email_domain: email_domain(email),
      clerk_id: clerk_id
    })

    case Accounts.create_user(user_params) do
      {:ok, user} ->
        Logger.info("Successfully created user from Clerk", %{user_id: user.id})

        # Sync external_id back to Clerk so JWT claims include userId
        sync_external_id_to_clerk(clerk_id, user.id)

        {:ok, user}

      {:error, changeset} ->
        Logger.error("Failed to create user from Clerk", %{
          errors: inspect(changeset.errors)
        })

        {:error, changeset}
    end
  end

  defp maybe_update_user(user, claims, opts) do
    if Keyword.get(opts, :update_on_sync, false) do
      attrs = %{name: extract_name_from_claims(claims), avatar_url: claims["image_url"]}

      case Accounts.update_user(user, attrs) do
        {:ok, updated_user} -> {:ok, updated_user}
        # Update failed, but user exists - return existing user
        {:error, _changeset} -> {:ok, user}
      end
    else
      {:ok, user}
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp extract_name_from_claims(claims) do
    first_name = claims["first_name"] || ""
    last_name = claims["last_name"] || ""

    name = String.trim("#{first_name} #{last_name}")

    if name == "" do
      case claims["email"] do
        nil -> "User"
        email -> email |> String.split("@") |> List.first()
      end
    else
      name
    end
  end

  defp extract_email_from_clerk_user(clerk_user) do
    case clerk_user["email_addresses"] do
      [first | _] -> first["email_address"]
      _ -> nil
    end
  end

  # Parse userId from claims - handles string or integer
  defp parse_user_id(nil), do: nil
  defp parse_user_id(id) when is_integer(id), do: id

  defp parse_user_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> int_id
      _ -> nil
    end
  end

  defp parse_user_id(_), do: nil

  defp email_domain(nil), do: "unknown"
  defp email_domain(email), do: email |> String.split("@") |> List.last()

  # Sync external_id back to Clerk so subsequent JWT tokens include userId.
  # Fire-and-forget — we don't block user creation if it fails.
  defp sync_external_id_to_clerk(clerk_id, user_id) when is_binary(clerk_id) do
    if clerk_configured?() do
      do_sync_external_id_to_clerk(clerk_id, user_id)
    else
      :ok
    end
  end

  defp sync_external_id_to_clerk(nil, _user_id), do: :ok

  defp clerk_configured? do
    not is_nil(Keyword.get(Application.get_env(:cinegraph, :clerk, []), :secret_key))
  end

  # Durable + retried (vs. a fire-and-forget Task that's lost on crash): enqueue
  # an Oban job that pushes external_id to Clerk. Per project guideline, external
  # writes go through Oban, not unsupervised tasks.
  defp do_sync_external_id_to_clerk(clerk_id, user_id) do
    case %{clerk_id: clerk_id, user_id: user_id}
         |> Cinegraph.Workers.SyncClerkExternalId.new()
         |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue Clerk external_id sync", %{
          clerk_id: clerk_id,
          user_id: user_id,
          reason: inspect(reason)
        })

        :ok
    end
  end
end
