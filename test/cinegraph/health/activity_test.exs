defmodule Cinegraph.Health.ActivityTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Health.Activity

  describe "today/0 + for_date/1" do
    test "returns the contract shape" do
      activity = Activity.today(bypass_cache: true)

      assert %{
               date: %Date{},
               movies_added: m,
               people_added: p,
               ceremonies_updated: c,
               omdb_fetches: o,
               jobs_completed: jc,
               jobs_failed: jf
             } = activity

      Enum.each([m, p, c, o, jc, jf], fn count ->
        assert is_integer(count) and count >= 0
      end)
    end

    test "for_date/1 accepts a Date and returns counters for that date" do
      yesterday = Date.add(Date.utc_today(), -1)
      activity = Activity.for_date(yesterday, bypass_cache: true)
      assert activity.date == yesterday
    end
  end

  describe "recent/1" do
    test "returns one row per day, most recent first" do
      rows = Activity.recent(3)
      assert length(rows) == 3
      [today, yesterday, day_before] = rows
      assert today.date == Date.utc_today()
      assert yesterday.date == Date.add(today.date, -1)
      assert day_before.date == Date.add(today.date, -2)
    end
  end
end
