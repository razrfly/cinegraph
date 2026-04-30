defmodule CinegraphWeb.MovieLive.GenreEmoji do
  @moduledoc """
  TMDb genre id → leading emoji used on the V2 movies page genre chips.

  Falls back to `🎞️` for unknown ids so a future TMDb addition does not break
  rendering. Mapping documented in issue #787 (Phase 2).
  """

  @emoji %{
    28 => "🥊",
    12 => "🗺️",
    16 => "🎨",
    35 => "😂",
    80 => "🔫",
    99 => "🎤",
    18 => "🎭",
    10_751 => "👪",
    14 => "🧙",
    36 => "📜",
    27 => "👻",
    10_402 => "🎵",
    9_648 => "🔎",
    10_749 => "💞",
    878 => "🚀",
    53 => "🔪",
    10_752 => "⚔️",
    37 => "🤠",
    10_770 => "📺"
  }

  @fallback "🎞️"

  @doc "Returns the emoji string for a given TMDb genre id, or the fallback."
  @spec for_id(integer() | String.t() | nil) :: String.t()
  def for_id(id) when is_integer(id), do: Map.get(@emoji, id, @fallback)

  def for_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> for_id(int)
      _ -> @fallback
    end
  end

  def for_id(_), do: @fallback
end
