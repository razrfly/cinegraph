defmodule Cinegraph.Workers.SyncClerkExternalId do
  @moduledoc """
  Pushes a local `users.id` back to Clerk as the user's `external_id` (#838).

  Once Clerk stores `external_id`, subsequent session JWTs carry the `userId`
  claim, letting us resolve the canonical local user by primary key instead of
  by email. Runs as an Oban job (not a fire-and-forget `Task`) so the back-sync
  is durable and retried with backoff if the Clerk API is briefly unavailable.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 5

  alias Cinegraph.Auth.Clerk.Client

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"clerk_id" => clerk_id, "user_id" => user_id}})
      when is_binary(clerk_id) do
    case Client.update_user(clerk_id, %{external_id: to_string(user_id)}) do
      {:ok, _} ->
        Logger.info("Synced external_id to Clerk", %{clerk_id: clerk_id, user_id: user_id})
        :ok

      {:error, reason} ->
        # Return the error so Oban retries with backoff.
        Logger.warning("Clerk external_id sync failed (will retry)", %{
          clerk_id: clerk_id,
          user_id: user_id,
          reason: inspect(reason)
        })

        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("SyncClerkExternalId got unexpected args: #{inspect(args)}")
    {:discard, :invalid_args}
  end
end
