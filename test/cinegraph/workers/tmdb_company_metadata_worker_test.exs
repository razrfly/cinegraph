defmodule Cinegraph.Workers.TMDbCompanyMetadataWorkerTest do
  use Cinegraph.DataCase, async: true

  alias Cinegraph.Workers.TMDbCompanyMetadataWorker

  describe "perform/1" do
    test "discards malformed company_id strings" do
      assert {:discard, :invalid_company_id} =
               TMDbCompanyMetadataWorker.perform(%Oban.Job{
                 args: %{"company_id" => "not-a-company-id"}
               })
    end

    test "discards missing company_id args" do
      assert {:discard, :invalid_args} =
               TMDbCompanyMetadataWorker.perform(%Oban.Job{args: %{}})
    end
  end
end
