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
    {"GIT_TERMINAL_PROMPT", "0"},
    {"GIT_ASKPASS", ""},
    {"SSH_ASKPASS", ""}
  ]

  @typedoc """
  Which credentials a Git process may use.

  `no_credentials` is the global configuration Git would otherwise inherit, replaced by nothing.
  `{:credentials, path}` replaces it with a file the caller wrote, which names each credential and
  the single origin and repository path it may be sent to. There is no third value: a Git process
  either has this biot's credentials or it has none.
  """
  @type scope :: :no_credentials | {:credentials, String.t()}

  @doc """
  The environment every Git process Biot starts runs with, whether the node runs it or a fetch
  worker's Nix does.

  The credential arrives as a configuration file and never as an argument or a variable of its
  own, so it is not in any process's command line and not in any environment a child inherits.
  """
  @spec environment(scope()) :: [{String.t(), String.t()}]
  def environment(scope), do: [{"GIT_CONFIG_GLOBAL", global_config(scope)} | @environment]

  defp global_config(:no_credentials), do: "/dev/null"
  defp global_config({:credentials, path}), do: path

  # What Git says when it has no usable credential for a repository, and what a server says back
  # when the one it was given is not accepted. Both mean the same thing to the node: this source
  # needs a credential it does not have.
  @authentication_signatures [
    "could not read Username",
    "Authentication failed",
    "HTTP Basic: Access denied",
    "returned error: 401",
    "returned error: 403"
  ]

  @doc """
  Whether one Git failure is a missing credential, and for which of the sources it could be about.

  This is the one definition of that question. The node's own clone asks it about the repository it
  was cloning, and the fetch phase asks it about every source its selection named, because Nix
  reports the whole worker's output and only the message says which source stopped.

  A message that names no candidate, or that cannot tell two of them apart, stays an ordinary
  failure. Guessing would turn a misspelled URL into a biot that waits for a credential nobody can
  deliver, and naming the wrong one of two repositories on a single host would leave an owner who
  supplied exactly what was asked for still waiting.
  """
  @spec authentication_failure(String.t(), [RepositorySource.t()]) ::
          {:credential_required, RepositorySource.t()} | :none
  def authentication_failure(output, sources) when is_binary(output) and is_list(sources) do
    if Enum.any?(@authentication_signatures, &String.contains?(output, &1)),
      do: named_source(output, sources),
      else: :none
  end

  # A URL decides it; an origin decides it only when no URL did. Two URLs the output names equally
  # stop there rather than falling back, because an origin cannot tell apart what a URL could not.
  defp named_source(output, sources) do
    case unique_longest(output, sources, &RepositorySource.to_string/1) do
      {:ok, source} -> {:credential_required, source}
      :no_match -> named_by_origin(output, sources)
      :ambiguous -> :none
    end
  end

  defp named_by_origin(output, sources) do
    case unique_longest(output, sources, &RepositorySource.origin/1) do
      {:ok, source} -> {:credential_required, source}
      _other -> :none
    end
  end

  # The longest of the names the output contains is the one it is about, because a shorter one is
  # only there by prefixing it: one repository path prefixes another, and one origin prefixes the
  # same host on another port. Two of the same greatest length are two things the output names
  # equally, and choosing between them would be the guess this module exists to refuse.
  @spec unique_longest(String.t(), [RepositorySource.t()], (RepositorySource.t() -> String.t())) ::
          {:ok, RepositorySource.t()} | :no_match | :ambiguous
  defp unique_longest(output, sources, name) do
    case Enum.filter(sources, &String.contains?(output, name.(&1))) do
      [] -> :no_match
      named -> only_longest(named, name)
    end
  end

  defp only_longest(sources, name) do
    longest = sources |> Enum.map(&byte_size(name.(&1))) |> Enum.max()

    case Enum.filter(sources, &(byte_size(name.(&1)) == longest)) do
      [source] -> {:ok, source}
      _several -> :ambiguous
    end
  end

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
