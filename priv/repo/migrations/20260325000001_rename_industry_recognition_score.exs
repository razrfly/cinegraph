defmodule Cinegraph.Repo.Migrations.RenameIndustryRecognitionScore do
  use Ecto.Migration

  def change do
    rename table(:movie_score_caches), :industry_recognition_score,
      to: :festival_recognition_score
  end
end
