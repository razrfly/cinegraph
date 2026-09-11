defmodule Cinegraph.Configuration do
  @moduledoc false

  @doc "Returns a configured secret or raises when it is blank."
  def require_non_blank!(name, value) when is_binary(value) do
    if String.trim(value) == "" do
      raise ArgumentError, "#{name} must not be blank"
    end

    value
  end

  def require_non_blank!(name, _value) do
    raise ArgumentError, "#{name} must not be blank"
  end
end
