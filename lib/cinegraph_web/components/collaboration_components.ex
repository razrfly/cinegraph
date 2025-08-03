defmodule CinegraphWeb.CollaborationComponents do
  @moduledoc """
  Collaboration-specific UI components
  """
  
  def strength_color(:very_strong), do: "bg-green-100 text-green-800"
  def strength_color(:strong), do: "bg-blue-100 text-blue-800"
  def strength_color(:moderate), do: "bg-gray-100 text-gray-800"
  def strength_color(_), do: "bg-gray-100 text-gray-800"
  
  def humanize_strength(:very_strong), do: "Very Strong"
  def humanize_strength(:strong), do: "Strong"
  def humanize_strength(:moderate), do: "Moderate"
  def humanize_strength(_), do: "Moderate"
  
  @doc """
  Returns the ordinal suffix for a number (st, nd, rd, th)
  """
  def ordinal_suffix(n) when is_integer(n) do
    cond do
      rem(n, 100) in [11, 12, 13] -> "th"
      rem(n, 10) == 1 -> "st"
      rem(n, 10) == 2 -> "nd"
      rem(n, 10) == 3 -> "rd"
      true -> "th"
    end
  end
  def ordinal_suffix(_), do: ""

  @doc """
  Formats a number with its ordinal suffix (1st, 2nd, 3rd, etc.)
  """
  def format_ordinal(n) when is_integer(n) do
    "#{n}#{ordinal_suffix(n)}"
  end
  def format_ordinal(_), do: ""
end