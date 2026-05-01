defmodule CinegraphWeb.MovieLive.IndexV2Components.ParamHelpers do
  @moduledoc false

  @doc false
  def normalize_people_filter(params) when is_map(params) do
    cond do
      filter_value_present?(params["people_ids"]) ->
        params
        |> Map.put("people", params["people_ids"])
        |> Map.delete("people_ids")

      true ->
        Map.delete(params, "people_ids")
    end
  end

  defp filter_value_present?(nil), do: false
  defp filter_value_present?(""), do: false
  defp filter_value_present?([]), do: false

  defp filter_value_present?(list) when is_list(list),
    do: Enum.any?(list, &filter_value_present?/1)

  defp filter_value_present?(_), do: true
end
