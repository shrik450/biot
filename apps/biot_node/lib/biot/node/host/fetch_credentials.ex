defmodule Biot.Node.Host.FetchCredentials do
  @moduledoc """
  Owns the source credentials the trusted fetch phase may use, and the Git configuration that
  binds each one to a single origin and repository path.

  A credential is stored as what it has to become: one `[http "<source>"]` section naming the
  authorization header to send and refusing to follow redirects. Storing the value already scoped
  is what makes the scope impossible to lose between here and the fetch. A value has no other
  form on this node, and it never reaches a command line or an environment variable; the fetch
  worker reads it through the read-only mount of this directory alone.

  One file per source, named for the digest of its URL, so delivery writes one file and removal
  deletes one, and a file name carries no repository.
  """

  alias Biot.Node.Allocation
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.FileSystem
  alias Biot.Node.Host.Outcome
  alias Biot.Node.Host.Paths
  alias Biot.Node.Host.Podman
  alias Biot.Protocol.AuthorizationValue
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SecretOutcome

  require Logger

  # The allocation's user owns a credential and the node's group may read it; the mode is what
  # says the group may only read. `Biot.Node.Host.Podman.share/3` explains why both need it.
  @file_mode 0o440
  # The two names must not overlap: an include file that matched the fragment pattern would list
  # itself, and Git follows an include until it gives up rather than ignoring the loop.
  @fragment_extension ".credential"
  @include_name "include.config"

  @spec put(Config.t(), Allocation.t(), RepositorySource.t(), AuthorizationValue.t()) ::
          SecretOutcome.t()
  def put(config, %Allocation{} = allocation, %RepositorySource{} = source, value) do
    directory = Paths.fetch_credentials(config, allocation.biot_id)

    case FileSystem.directory(directory) do
      {:present, :directory} -> publish(config, allocation, directory, source, value)
      :absent -> :no_allocation
      {:error, reason} -> failed("the credential directory could not be inspected", reason)
    end
  end

  @spec remove(Config.t(), Allocation.t(), RepositorySource.t()) :: SecretOutcome.t()
  def remove(config, %Allocation{} = allocation, %RepositorySource{} = source) do
    directory = Paths.fetch_credentials(config, allocation.biot_id)

    case FileSystem.directory(directory) do
      {:present, :directory} -> unlink(Path.join(directory, fragment_name(source)))
      :absent -> :no_allocation
      {:error, reason} -> failed("the credential directory could not be inspected", reason)
    end
  end

  @doc """
  Writes the one file Git is pointed at, naming every credential this biot holds.

  Git is given a global configuration file rather than a value, and that file includes the
  fragments by relative path, so no value is copied to build it and the same file means the same
  thing to the node and to the fetch worker, which see the directory at different absolute paths.

  A biot with no credentials gets an empty file, which is what an unconfigured Git already expects,
  so no caller has to ask whether there are any.
  """
  @spec write_include(Config.t(), Allocation.t()) :: :ok | {:error, Outcome.t()}
  def write_include(config, %Allocation{} = allocation) do
    directory = Paths.fetch_credentials(config, allocation.biot_id)

    with {:ok, names} <- fragment_names(directory),
         :ok <-
           place(
             config,
             allocation,
             directory,
             @include_name,
             Enum.map(names, &"[include]\n\tpath = #{&1}\n")
           ) do
      :ok
    else
      {:error, %Outcome{} = outcome} -> {:error, outcome}
      {:error, reason} -> {:error, Outcome.from_reason(reason)}
    end
  end

  @doc "The Git configuration scope a caller runs with: this biot's credentials, at `path`."
  @spec scope(Config.t(), BiotId.t()) :: {:credentials, String.t()}
  def scope(config, %BiotId{} = biot_id) do
    {:credentials, Path.join(Paths.fetch_credentials(config, biot_id), @include_name)}
  end

  @doc """
  Which of `sources` this biot already holds a credential for.

  The stored fragment is the node's record of a delivery: one file per source, named for the digest
  of its URL, so a delivered credential is held for every later revision without any other durable
  state. Reading the directory once answers the whole set, which is what lets a caller ask before
  it runs Git whether the failure it has not seen yet would be a first wait or a refusal.
  """
  @spec held_sources(Config.t(), Allocation.t(), [RepositorySource.t()]) :: [RepositorySource.t()]
  def held_sources(config, %Allocation{} = allocation, sources) do
    directory = Paths.fetch_credentials(config, allocation.biot_id)

    case fragment_names(directory) do
      {:ok, names} -> Enum.filter(sources, &(fragment_name(&1) in names))
      # A directory the node cannot list holds nothing the node can offer, and the include file
      # written from the same directory fails before Git runs on it.
      {:error, _reason} -> []
    end
  end

  @doc "The include file's own name, which is the same inside a worker as it is on the node."
  @spec include_name() :: String.t()
  def include_name, do: @include_name

  defp fragment_names(directory) do
    case File.ls(directory) do
      {:ok, entries} ->
        {:ok, entries |> Enum.filter(&String.ends_with?(&1, @fragment_extension)) |> Enum.sort()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish(config, allocation, directory, source, value) do
    case place(config, allocation, directory, fragment_name(source), fragment(source, value)) do
      :ok -> :ok
      {:error, reason} -> failed("a delivered credential could not be published", reason)
    end
  end

  # The fetch worker runs as the allocation's user and the node's own clone runs as the node, so a
  # credential is shared with the node's group rather than handed over outright.
  defp place(config, allocation, directory, name, content) do
    prepare = fn path ->
      with :ok <- File.chmod(path, @file_mode), do: Podman.share(config, allocation, [path])
    end

    FileSystem.publish(directory, name, content, prepare)
  end

  defp unlink(path) do
    case FileSystem.unlink(path) do
      :ok -> :ok
      {:error, reason} -> failed("a credential could not be removed", reason)
    end
  end

  @doc """
  The Git configuration one credential becomes.

  `extraHeader` is quoted and escaped because a Git value that starts a comment or ends a quoted
  string would otherwise change what the rest of the section means. `followRedirects = false` is
  the whole of "a redirect cannot carry it elsewhere": a header curl would resend to the redirect
  target is a header for a request Git never makes.
  """
  @spec fragment(RepositorySource.t(), AuthorizationValue.t()) :: iodata()
  def fragment(%RepositorySource{} = source, value) do
    [
      "[http ",
      quoted(RepositorySource.to_string(source)),
      "]\n\textraHeader = ",
      quoted("Authorization: " <> AuthorizationValue.reveal(value)),
      "\n\tfollowRedirects = false\n"
    ]
  end

  @spec fragment_name(RepositorySource.t()) :: String.t()
  def fragment_name(%RepositorySource{} = source) do
    digest =
      :sha256
      |> :crypto.hash(RepositorySource.to_string(source))
      |> Base.encode16(case: :lower)

    digest <> @fragment_extension
  end

  defp quoted(value) do
    escaped = value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    [?", escaped, ?"]
  end

  defp failed(message, reason) do
    Logger.warning("#{message}: #{inspect(reason)}")
    {:failure, :write_failed}
  end
end
