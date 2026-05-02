defmodule CinegraphWeb.MovieLive.ShowV2.ProductionDetails do
  @moduledoc """
  Production-company details for the V2 movie show page.
  """

  use CinegraphWeb, :html

  attr :production_companies, :list, required: true

  def production_details(assigns) do
    ~H"""
    <dd class="text-mist-950 text-right">
      <.link
        :for={{company, index} <- @production_companies |> Enum.take(2) |> Enum.with_index()}
        navigate={~p"/companies/#{production_company_slug_or_id(company)}"}
        class="underline decoration-mist-950/15 underline-offset-4 hover:text-mist-700"
      >
        <span :if={index > 0} class="text-mist-500 no-underline"> · </span>{production_company_name(
          company
        )}
      </.link>
    </dd>
    """
  end

  defp production_company_name(%{name: name}), do: name
  defp production_company_name(%{production_company: %{name: name}}), do: name
  defp production_company_name(_company), do: "-"

  defp production_company_slug_or_id(%{slug: slug}) when is_binary(slug) and slug != "", do: slug
  defp production_company_slug_or_id(%{id: id}), do: id

  defp production_company_slug_or_id(%{production_company: company}),
    do: production_company_slug_or_id(company)
end
