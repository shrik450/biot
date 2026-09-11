defmodule Biot.Node.Host.Git do
  @moduledoc """
  The one shape every Biot-managed Git call takes.

  Biot runs Git in two places: the node clones a Biot's checkout, and a fetch worker's Nix runs
  Git to pin and stage sources. Both get the same hardening, so there is one definition of it
  rather than one per caller.

  The rules are the model's: HTTPS only, including across redirects, because Git applies the
  protocol allowlist to every redirect it follows; no inherited system or user configuration, so
  an operator's `~/.gitconfig` cannot add a credential helper or a URL rewrite; no credential
  helper, no prompt, and no askpass program, so a private repository fails instead of waiting or
  reading the node's credentials; no submodule recursion, so one parsed URL fetches one
  repository; and an empty template, so no hook or configuration reaches the new clone.

  `Biot.Protocol.RepositorySource` rejects everything but HTTPS before a URL reaches here, so
  these settings close the paths a redirect or a configuration file could otherwise open.
  """

  alias Biot.Node.Host.Config
  alias Biot.Node.Host.Paths
  alias Biot.Protocol.RepositorySource

  @environment [
    {"GIT_ALLOW_PROTOCOL", "https"},
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_TERMINAL_PROMPT", "0"},
    {"GIT_ASKPASS", ""},
    {"SSH_ASKPASS", ""}
  ]

  @doc """
  The environment every Git process Biot starts runs with, whether the node runs it or a fetch
  worker's Nix does.
  """
  @spec environment() :: [{String.t(), String.t()}]
  def environment, do: @environment

  @doc "One clone of one parsed repository into one destination the caller owns."
  @spec clone_arguments(Config.t(), RepositorySource.t(), String.t()) :: [String.t()]
  def clone_arguments(config, repository, destination) do
    [
      "-c",
      "credential.helper=",
      "-c",
      "submodule.recurse=false",
      "clone",
      "--no-recurse-submodules",
      "--template",
      Paths.git_template(config),
      "--",
      RepositorySource.to_string(repository),
      destination
    ]
  end
end
