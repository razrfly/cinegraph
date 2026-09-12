defmodule CinegraphWeb.Admin.ApiCredentialsLive do
  use CinegraphWeb, :admin_live_view

  alias Cinegraph.ApiCredentials

  @impl true
  def mount(_params, %{"admin_operator" => operator}, socket) when is_binary(operator) do
    {:ok,
     socket
     |> assign(
       page_title: "API credentials",
       operator: operator,
       client: nil,
       keys: [],
       issued: nil
     )
     |> assign(client_form: to_form(%{}, as: :client), key_form: to_form(%{}, as: :key))
     |> assign(clients: ApiCredentials.list_clients())}
  end

  def mount(_params, _session, socket), do: {:ok, redirect(socket, to: "/")}

  @impl true
  def handle_params(params, _uri, socket) do
    slug = params["client"]
    client = if is_binary(slug), do: ApiCredentials.get_client_by_slug(slug)
    {:noreply, socket |> assign(client: client, issued: nil) |> reload()}
  end

  @impl true
  def handle_event("create_client", %{"client" => params}, socket) do
    attrs = %{
      slug: params["slug"],
      label: params["label"],
      owner_contact: params["owner_contact"],
      environment: params["environment"],
      scopes: ["catalog:read"]
    }

    case ApiCredentials.create_client(attrs) do
      {:ok, client} ->
        {:noreply,
         socket
         |> assign(client_form: to_form(%{}, as: :client))
         |> put_flash(:info, "Client created. You can now issue its first key.")
         |> push_patch(to: ~p"/admin/api-credentials?client=#{client.slug}")}

      {:error, changeset} ->
        {:noreply, assign(socket, client_form: to_form(changeset, as: :client))}
    end
  end

  def handle_event("issue_key", _params, %{assigns: %{issued: issued}} = socket)
      when not is_nil(issued), do: {:noreply, socket}

  def handle_event("issue_key", %{"key" => params}, %{assigns: %{client: client}} = socket)
      when not is_nil(client) do
    with {:ok, expiry} <- expiry(params["expiry"]),
         {:ok, key, token} <-
           ApiCredentials.issue_key(client.slug, %{
             label: params["label"],
             created_by: socket.assigns.operator,
             expires_at: expiry
           }) do
      Process.send_after(self(), {:clear_issued, key.public_id}, 120_000)

      {:noreply,
       socket
       |> reload()
       |> assign(
         issued: %{public_id: key.public_id, token: token},
         key_form: to_form(%{}, as: :key)
       )}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, key_form: to_form(changeset, as: :key))}

      {:error, :expiry_choice_required} ->
        {:noreply, put_flash(socket, :error, "Choose when this key should expire.")}

      _ ->
        {:noreply,
         socket
         |> reload()
         |> put_flash(:error, "Could not issue a key. Check that the client is enabled.")}
    end
  end

  def handle_event("dismiss_key", _params, socket), do: {:noreply, assign(socket, issued: nil)}

  def handle_event("revoke_key", %{"id" => public_id}, socket) do
    # Re-resolve against the selected client's keys; DOM values are untrusted.
    with %{slug: slug} <- socket.assigns.client,
         {:ok, keys} <- ApiCredentials.list_keys(slug),
         true <- Enum.any?(keys, &(&1.public_id == public_id)),
         {:ok, _} <- ApiCredentials.revoke_key(public_id) do
      {:noreply,
       socket
       |> assign(issued: nil)
       |> reload()
       |> put_flash(:info, "Key revoked. New requests using it will be denied.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Key not found for this client.")}
    end
  end

  def handle_event("disable_client", _params, %{assigns: %{client: client}} = socket)
      when not is_nil(client) do
    case ApiCredentials.disable_client(client.slug) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(issued: nil)
         |> reload()
         |> put_flash(:info, "Client disabled. All of its keys now deny access.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not disable this client.")}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:clear_issued, id}, socket) do
    issued = socket.assigns.issued

    {:noreply,
     if(issued && issued.public_id == id, do: assign(socket, issued: nil), else: socket)}
  end

  defp reload(socket) do
    client = socket.assigns.client
    client = if client, do: ApiCredentials.get_client_by_slug(client.slug)
    keys = if client, do: elem(ApiCredentials.list_keys(client.slug), 1), else: []

    keys =
      Enum.map(
        keys,
        &Map.take(&1, [:public_id, :label, :created_by, :expires_at, :revoked_at, :inserted_at])
      )

    assign(socket, clients: ApiCredentials.list_clients(), client: client, keys: keys)
  end

  defp expiry("90"), do: {:ok, DateTime.add(DateTime.utc_now(), 90 * 86400)}
  defp expiry("365"), do: {:ok, DateTime.add(DateTime.utc_now(), 365 * 86400)}
  defp expiry("never"), do: {:ok, nil}
  defp expiry(_), do: {:error, :expiry_choice_required}

  defp key_status(%{revoked_at: revoked}) when not is_nil(revoked), do: "Revoked"
  defp key_status(%{expires_at: nil}), do: "Active"

  defp key_status(key),
    do:
      if(DateTime.compare(key.expires_at, DateTime.utc_now()) == :gt,
        do: "Active",
        else: "Expired"
      )

  defp date(nil), do: "No expiry"
  defp date(value), do: Calendar.strftime(value, "%d %b %Y")
end
