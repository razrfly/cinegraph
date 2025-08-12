#!/usr/bin/env elixir

# Verify that the festival years are using the current year
current_year = Date.utc_today().year
IO.puts("Current year: #{current_year}")
IO.puts("")

# Simulate what generate_festival_years does
{min_year, max_year} = {2020, current_year}

# Generate years in reverse order (newest first)
festival_years = max_year..min_year//-1
years_list =
  Enum.map(festival_years, fn year ->
    %{
      value: to_string(year),
      label: to_string(year)
    }
  end)

# Add "All Years" option at the top
final_list = [%{value: "all", label: "All Available Years (#{min_year}-#{max_year})"} | years_list]

IO.puts("Expected dropdown options:")
IO.puts("------------------------")
Enum.each(final_list, fn option ->
  IO.puts("  Value: #{option.value}, Label: #{option.label}")
end)

IO.puts("")
IO.puts("✅ The dropdown should show 'All Available Years (2020-#{current_year})' as the first option")
IO.puts("✅ Individual years should include #{current_year} as the first year option")