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
end