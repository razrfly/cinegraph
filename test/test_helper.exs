ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Cinegraph.Repo, :manual)

# Force Cinegraph.Repo.replica() to return the primary in tests so writes via
# Repo are visible to reads that go through Repo.replica(). Replica gets its
# own sandbox checkout that doesn't see primary-side inserts.
System.put_env("USE_REPLICA", "false")

# Initialize the R2 stub's ETS table (#890). Tests reset state between
# cases via R2Stub.reset!/0.
Cinegraph.Images.R2Stub.start!()
