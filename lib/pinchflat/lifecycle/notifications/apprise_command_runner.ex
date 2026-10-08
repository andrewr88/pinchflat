defmodule Pinchflat.Lifecycle.Notifications.AppriseCommandRunner do
  @moduledoc """
  A behaviour for running CLI commands against a notification backend (apprise).

  Used so we can implement Mox for testing without actually running the
  apprise command.
  """

  @callback run(nil | binary() | [binary()], keyword()) :: {:ok, binary()} | {:error, :no_servers} | {:error, binary()}
  @callback version() :: {:ok, binary()} | {:error, binary()}
end
