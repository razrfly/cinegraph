defmodule CinegraphWeb.ViewHelpers do
  @moduledoc """
  View helpers for safe handling of common operations in templates.

  Provides safe arithmetic operations, formatting functions, and other
  utilities to prevent errors in templates.
  """

  @doc """
  Safely divides two numbers, handling cases where the divisor might be zero or nil.

  ## Examples

      iex> safe_divide(10, 2)
      5.0
      
      iex> safe_divide(10, 0)
      nil
      
      iex> safe_divide(nil, 2)
      nil
      
      iex> safe_divide(Decimal.new("10.5"), Decimal.new("2.5"))
      Decimal.new("4.2")
  """
  def safe_divide(nil, _), do: nil
  def safe_divide(_, nil), do: nil
  def safe_divide(_, denom) when is_number(denom) and denom == 0, do: nil

  def safe_divide(%Decimal{} = numerator, %Decimal{} = denominator) do
    if Decimal.equal?(denominator, Decimal.new(0)) do
      nil
    else
      Decimal.div(numerator, denominator)
    end
  end

  def safe_divide(%Decimal{} = numerator, denom) when is_number(denom) do
    safe_divide(numerator, to_decimal(denom))
  end

  def safe_divide(numerator, %Decimal{} = denom) when is_number(numerator) do
    safe_divide(to_decimal(numerator), denom)
  end

  def safe_divide(numerator, denominator) when is_number(numerator) and is_number(denominator) do
    numerator / denominator
  end

  @doc """
  Safely multiplies two numbers, handling nil values.

  ## Examples

      iex> safe_multiply(5, 2)
      10
      
      iex> safe_multiply(nil, 2)
      nil
      
      iex> safe_multiply(Decimal.new("2.5"), Decimal.new("4"))
      Decimal.new("10.0")
  """
  def safe_multiply(nil, _), do: nil
  def safe_multiply(_, nil), do: nil

  def safe_multiply(%Decimal{} = a, %Decimal{} = b) do
    Decimal.mult(a, b)
  end

  def safe_multiply(%Decimal{} = a, b) when is_number(b) do
    Decimal.mult(a, to_decimal(b))
  end

  def safe_multiply(a, %Decimal{} = b) when is_number(a) do
    Decimal.mult(to_decimal(a), b)
  end

  def safe_multiply(a, b) when is_number(a) and is_number(b) do
    a * b
  end

  @doc """
  Safely adds two numbers, handling nil values.

  ## Examples

      iex> safe_add(5, 2)
      7
      
      iex> safe_add(nil, 2)
      2
      
      iex> safe_add(5, nil)
      5
      
      iex> safe_add(Decimal.new("2.5"), Decimal.new("4"))
      Decimal.new("6.5")
  """
  def safe_add(nil, b), do: b
  def safe_add(a, nil), do: a

  def safe_add(%Decimal{} = a, %Decimal{} = b) do
    Decimal.add(a, b)
  end

  def safe_add(%Decimal{} = a, b) when is_number(b) do
    Decimal.add(a, to_decimal(b))
  end

  def safe_add(a, %Decimal{} = b) when is_number(a) do
    Decimal.add(to_decimal(a), b)
  end

  def safe_add(a, b) when is_number(a) and is_number(b) do
    a + b
  end

  @doc """
  Safely subtracts two numbers, handling nil values.

  ## Examples

      iex> safe_subtract(5, 2)
      3
      
      iex> safe_subtract(nil, 2)
      nil
      
      iex> safe_subtract(5, nil)
      nil
      
      iex> safe_subtract(Decimal.new("5.5"), Decimal.new("2"))
      Decimal.new("3.5")
  """
  def safe_subtract(nil, _), do: nil
  def safe_subtract(_, nil), do: nil

  def safe_subtract(%Decimal{} = a, %Decimal{} = b) do
    Decimal.sub(a, b)
  end

  def safe_subtract(%Decimal{} = a, b) when is_number(b) do
    Decimal.sub(a, to_decimal(b))
  end

  def safe_subtract(a, %Decimal{} = b) when is_number(a) do
    Decimal.sub(to_decimal(a), b)
  end

  def safe_subtract(a, b) when is_number(a) and is_number(b) do
    a - b
  end

  @doc """
  Formats a number as currency, handling nil values.

  ## Examples

      iex> format_currency(1234567)
      "$1,234,567"
      
      iex> format_currency(nil)
      "N/A"
      
      iex> format_currency(Decimal.new("1234.56"))
      "$1,234.56"
  """
  def format_currency(nil), do: "N/A"

  def format_currency(%Decimal{} = amount) do
    amount
    |> Decimal.round(2)
    |> Decimal.to_float()
    |> then(&("$" <> Number.Delimit.number_to_delimited(&1, precision: 2)))
  end

  def format_currency(amount) when is_integer(amount) do
    "$" <> Number.Delimit.number_to_delimited(amount, precision: 0)
  end

  def format_currency(amount) when is_float(amount) do
    "$" <> Number.Delimit.number_to_delimited(amount, precision: 2)
  end

  @doc """
  Formats a percentage value, handling nil values and safe division.

  ## Examples

      iex> format_percentage(0.75)
      "75%"
      
      iex> format_percentage(nil)
      "N/A"
      
      iex> format_percentage(3, 4)
      "75%"
      
      iex> format_percentage(1, 0)
      "N/A"
  """
  def format_percentage(nil), do: "N/A"

  def format_percentage(percentage) when is_number(percentage) do
    "#{round(percentage * 100)}%"
  end

  def format_percentage(%Decimal{} = percentage) do
    percentage
    |> Decimal.mult(Decimal.new(100))
    |> Decimal.to_float()
    |> round()
    |> then(&"#{&1}%")
  end

  def format_percentage(numerator, denominator) do
    case safe_divide(numerator, denominator) do
      nil -> "N/A"
      result -> format_percentage(result)
    end
  end

  @doc """
  Safely calculates average rating, handling empty lists or nil values.

  ## Examples

      iex> safe_average([1, 2, 3, 4, 5])
      3.0
      
      iex> safe_average([])
      nil
      
      iex> safe_average(nil)
      nil
  """
  def safe_average(nil), do: nil
  def safe_average([]), do: nil

  def safe_average(values) when is_list(values) do
    valid_values = Enum.reject(values, &is_nil/1)

    case valid_values do
      [] ->
        nil

      _ ->
        # Check if any values are Decimals
        if Enum.any?(valid_values, &match?(%Decimal{}, &1)) do
          sum =
            Enum.reduce(valid_values, Decimal.new(0), fn v, acc ->
              case v do
                %Decimal{} -> Decimal.add(acc, v)
                v when is_integer(v) -> Decimal.add(acc, Decimal.new(v))
                v when is_float(v) -> Decimal.add(acc, Decimal.from_float(v))
              end
            end)

          Decimal.div(sum, Decimal.new(length(valid_values)))
        else
          Enum.sum(valid_values) / length(valid_values)
        end
    end
  end

  @doc """
  Safely formats a number with precision, handling nil values.

  ## Examples

      iex> safe_round(3.14159, 2)
      3.14
      
      iex> safe_round(nil, 2)
      nil
      
      iex> safe_round(Decimal.new("3.14159"), 2)
      Decimal.new("3.14")
  """
  def safe_round(nil, _precision), do: nil

  def safe_round(%Decimal{} = number, precision) do
    Decimal.round(number, precision)
  end

  def safe_round(number, precision) when is_integer(number) and is_integer(precision) do
    Float.round(number * 1.0, precision)
  end

  def safe_round(number, precision) when is_float(number) and is_integer(precision) do
    Float.round(number, precision)
  end

  @doc """
  Safely converts a value to string, handling nil values.

  ## Examples

      iex> safe_to_string(123)
      "123"
      
      iex> safe_to_string(nil)
      ""
      
      iex> safe_to_string(Decimal.new("123.45"))
      "123.45"
  """
  def safe_to_string(nil), do: ""

  def safe_to_string(%Decimal{} = value) do
    Decimal.to_string(value)
  end

  def safe_to_string(value), do: to_string(value)

  # Private helper to convert numeric values to Decimal
  defp to_decimal(v) when is_integer(v), do: Decimal.new(v)
  defp to_decimal(v) when is_float(v), do: Decimal.from_float(v)
  defp to_decimal(%Decimal{} = v), do: v
end
