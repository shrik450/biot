defmodule Biot.Mix.TestEnv do
  @moduledoc false

  # The test aliases drop the database. A non-test environment would otherwise
  # lose its database before the test task rejects the environment.
  @spec require_test_env!([String.t()]) :: :ok
  def require_test_env!(_args) do
    if Mix.env() != :test do
      Mix.raise(
        "mix test requires MIX_ENV=test, got #{Mix.env()}; refusing to drop the #{Mix.env()} database"
      )
    end

    :ok
  end
end
