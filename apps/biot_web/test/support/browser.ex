defmodule BiotWeb.Browser do
  @moduledoc """
  Finds the Chrome driver and the browser it drives, for Wallaby.

  Wallaby wants both as absolute paths, and no two environments this suite runs in agree on
  where they are: Debian ships `chromium` and `chromium-driver`, Nix puts both under the store,
  and a GitHub runner has `chromedriver` beside Google Chrome. Searching `PATH` is what makes the
  suite portable; naming one layout is what made it pass on a runner and fail everywhere else.

  The environment variables win over the search so that a machine with several browsers can say
  which one to drive without editing the suite.
  """

  @driver_variable "BIOT_TEST_CHROMEDRIVER"
  @browser_variable "BIOT_TEST_CHROME"

  @driver_names ["chromedriver"]
  @browser_names ["chromium", "chromium-browser", "google-chrome", "google-chrome-stable"]

  @host_resolver_rule "--host-resolver-rules=MAP *.env.test 127.0.0.1"

  @doc """
  Points Wallaby at this machine's driver and browser.

  Raises with what to install when either is missing, because the alternative is Wallaby's own
  `DependencyError` naming a path nobody configured.
  """
  @spec configure!() :: :ok
  def configure! do
    driver = find!(@driver_variable, @driver_names, "chromium-driver")
    browser = find!(@browser_variable, @browser_names, "chromium")

    capabilities =
      Wallaby.Chrome.default_capabilities()
      |> update_in([:chromeOptions, :args], &(&1 ++ [@host_resolver_rule]))
      |> put_in([:chromeOptions, :binary], browser)

    Application.put_env(:wallaby, :chromedriver,
      path: driver,
      binary: browser,
      capabilities: capabilities
    )

    :ok
  end

  @doc "The rule that sends every preview hostname this suite invents back to the test endpoint."
  @spec host_resolver_rule() :: String.t()
  def host_resolver_rule, do: @host_resolver_rule

  defp find!(variable, names, package) do
    case System.get_env(variable) do
      nil -> search!(variable, names, package)
      path -> executable!(variable, path)
    end
  end

  defp search!(variable, names, package) do
    Enum.find_value(names, &System.find_executable/1) ||
      raise """
      the browser tests need #{Enum.join(names, " or ")} on PATH, and found none of them.

      Install the #{package} package, or set #{variable} to the executable to use.
      """
  end

  defp executable!(variable, path) do
    if File.regular?(path) do
      path
    else
      raise "#{variable} is set to #{inspect(path)}, which is not a file"
    end
  end
end
