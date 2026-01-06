# Calibration System Seeds
# Seeds reference lists and default scoring configurations

alias Cinegraph.Calibration
alias Cinegraph.Calibration.ScoringConfiguration

IO.puts("=== Seeding Calibration System ===")

# Seed known reference lists
IO.puts("Seeding reference lists...")

results = Calibration.seed_known_lists()
success_count = Enum.count(results, fn {:ok, _} -> true; _ -> false end)
IO.puts("  Created #{success_count} reference lists")

# Seed default scoring configuration
IO.puts("Seeding scoring configurations...")

{:ok, default_config} = Calibration.seed_default_configuration()
IO.puts("  Default configuration v#{default_config.version}: #{default_config.name}")

# Create recommended optimized configuration as draft
recommended = ScoringConfiguration.recommended_config()

case Calibration.get_scoring_configuration_by_version(2) do
  nil ->
    {:ok, rec_config} = Calibration.create_scoring_configuration(recommended)
    IO.puts("  Recommended configuration v#{rec_config.version}: #{rec_config.name} (draft)")

  existing ->
    IO.puts("  Recommended configuration v#{existing.version} already exists")
end

IO.puts("=== Calibration seeding complete ===")
