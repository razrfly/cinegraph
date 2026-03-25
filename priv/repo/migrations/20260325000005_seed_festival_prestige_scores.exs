defmodule Cinegraph.Repo.Migrations.SeedFestivalPrestigeScores do
  use Ecto.Migration

  def up do
    for {abbrev, win, nom, tier} <- [
          {"AMPAS", 100.0, 80.0, 1},
          {"CFF", 95.0, 75.0, 2},
          {"VIFF", 90.0, 70.0, 3},
          {"BIFF", 90.0, 70.0, 3},
          {"BAFTA", 85.0, 65.0, 4},
          {"HFPA", 80.0, 60.0, 5},
          {"SFF", 75.0, 60.0, 6},
          {"CCA", 70.0, 50.0, 7}
        ] do
      execute("""
        UPDATE festival_organizations
        SET win_score = #{win}, nom_score = #{nom}, prestige_tier = #{tier}
        WHERE abbreviation = '#{abbrev}'
      """)
    end
  end

  def down do
    execute("""
      UPDATE festival_organizations
      SET win_score = NULL, nom_score = NULL, prestige_tier = NULL
    """)
  end
end
