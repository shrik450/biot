defmodule Biot.Node.Host.Config do
  @moduledoc """
  The parsed operator settings used by host inspection and effects.

  Most settings are paths, executables, and bounds an operator can read from their names. Two are
  not, and this is the deployment-facing description of them.

  ## `BIOT_NODE_FETCH_CA_BUNDLE`

  Optional. The absolute path to the certificate authorities the trusted fetch phase trusts, for an
  operator who runs a Git host the builder image's own roots do not cover.

  It **replaces** that trust store; it does not add to it, the way `SSL_CERT_FILE` does not add to
  it for any other tool. A file holding only a private authority therefore makes public fetches
  fail, including the base package set. The file must hold every authority a fetch needs. Build a
  complete one by putting the image's own roots first:

      podman run --rm --network none "$BIOT_NODE_BUILDER_IMAGE" \
        cat /nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt > roots.pem
      cat roots.pem private-authority.pem > /etc/biot/fetch-ca-bundle.pem

  Leave it unset unless a fetch actually needs it. It reaches the fetch phase alone: no user build
  and no runtime trusts an operator's authority, and the node's own checkout clone trusts whatever
  the node host trusts, so an authority needed for a private checkout belongs in the host's own
  store as well.

  ## `BIOT_NODE_BUILDER_IMAGE`

  Required, and must name a digest rather than a tag. "The current release's pinned image" is a
  trust statement, and a tag is not a pin.

  ## `BIOT_NODE_RUNTIME_ROOT`

  Required, and short. It holds one directory per running Biot, and in it the Unix socket the
  node uses to reach that Biot's agent. Nothing under it outlives a reboot, so `/run/biot` is the
  usual answer and a systemd `RuntimeDirectory=biot` produces it.

  It is separate from `BIOT_NODE_DATA_ROOT` because a socket address is not data. Linux caps a
  Unix socket path at 108 bytes including its terminating NUL, so every byte of the directory
  holding one is a correctness concern, while the data root wants to be wherever the disk is and
  is free to be long. Keeping both jobs in one setting made the data root's length break the
  node, which is why they are two.
  """

  alias Biot.Node.Host.Command
  alias Biot.Node.Host.FileSystem
  alias Biot.Node.Host.Paths
  alias Biot.Protocol.Platform

  @enforce_keys [
    :data_root,
    :runtime_root,
    :uid_range_base,
    :uid_range_count,
    :uid_range_limit,
    :git_executable,
    :podman_executable,
    :setsid_executable,
    :mkfifo_executable,
    :head_executable,
    :cat_executable,
    :sleep_executable,
    :podman_network_command,
    :builder_image,
    :build_support_dir,
    :fetch_ca_bundle,
    :binary_cache_urls,
    :binary_cache_keys,
    :nixpkgs_repository,
    :nixpkgs_ref,
    :command_timeout_ms,
    :worker_timeout_ms,
    :command_max_output_bytes,
    :command_max_stderr_bytes,
    :runtime_log_max_bytes,
    :platform
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          data_root: String.t(),
          runtime_root: String.t(),
          uid_range_base: non_neg_integer(),
          uid_range_count: pos_integer(),
          uid_range_limit: pos_integer(),
          git_executable: String.t(),
          podman_executable: String.t(),
          setsid_executable: String.t(),
          mkfifo_executable: String.t(),
          head_executable: String.t(),
          cat_executable: String.t(),
          sleep_executable: String.t(),
          podman_network_command: String.t(),
          builder_image: String.t(),
          build_support_dir: String.t(),
          fetch_ca_bundle: String.t() | nil,
          binary_cache_urls: [String.t()],
          binary_cache_keys: [String.t()],
          nixpkgs_repository: String.t(),
          nixpkgs_ref: String.t(),
          command_timeout_ms: pos_integer(),
          worker_timeout_ms: pos_integer(),
          command_max_output_bytes: pos_integer(),
          command_max_stderr_bytes: pos_integer(),
          runtime_log_max_bytes: pos_integer(),
          platform: Platform.t()
        }

  @doc """
  Parses the host settings and keeps them for every later reader, so no reader parses them again
  or scans `PATH` again. `Biot.Node.Host.Setup` calls this at boot, before any process that reads
  the settings starts.
  """
  @spec load() :: {:ok, t()} | {:error, term()}
  def load do
    with {:ok, config} <- parse_application() do
      :persistent_term.put(__MODULE__, config)
      {:ok, config}
    end
  end

  @doc "The settings `load/0` kept. A node whose host is not configured has none."
  @spec current() :: {:ok, t()} | {:error, :not_loaded}
  def current do
    case :persistent_term.get(__MODULE__, nil) do
      nil -> {:error, :not_loaded}
      config -> {:ok, config}
    end
  end

  # Every process that calls this starts after `Biot.Node.Host.Setup` loaded the settings.
  @spec current!() :: t()
  def current! do
    {:ok, config} = current()
    config
  end

  defp parse_application do
    with {:ok, platform} <- Platform.current(),
         {:ok, data_root} <- absolute_path(:data_root),
         {:ok, runtime_root} <- absolute_path(:runtime_root),
         :ok <- agent_socket_path(runtime_root),
         {:ok, uid_range_base} <- non_negative_integer(:uid_range_base),
         {:ok, uid_range_count} <- positive_integer(:uid_range_count),
         {:ok, uid_range_limit} <- positive_integer(:uid_range_limit),
         :ok <- uid_range(uid_range_base, uid_range_count, uid_range_limit),
         {:ok, fetch_ca_bundle} <- fetch_ca_bundle(),
         {:ok, builder_image} <- builder_image(),
         {:ok, binary_cache_urls} <- cache_setting(:binary_cache_urls),
         {:ok, binary_cache_keys} <- cache_setting(:binary_cache_keys),
         {:ok, setsid_executable} <- executable(:setsid_executable),
         {:ok, mkfifo_executable} <- executable(:mkfifo_executable),
         {:ok, head_executable} <- executable(:head_executable),
         {:ok, cat_executable} <- executable(:cat_executable),
         {:ok, sleep_executable} <- executable(:sleep_executable),
         {:ok, podman_network_command} <- rootless_network_command(),
         {:ok, command_timeout_ms} <- positive_integer(:host_command_timeout_ms),
         {:ok, command_max_output_bytes} <- positive_integer(:host_command_max_output_bytes),
         {:ok, command_max_stderr_bytes} <-
           positive_integer(:host_command_max_stderr_bytes),
         {:ok, worker_timeout_ms} <- positive_integer(:worker_timeout_ms),
         {:ok, runtime_log_max_bytes} <- positive_integer(:runtime_log_max_bytes) do
      {:ok,
       %__MODULE__{
         data_root: data_root,
         runtime_root: runtime_root,
         uid_range_base: uid_range_base,
         uid_range_count: uid_range_count,
         uid_range_limit: uid_range_limit,
         git_executable: setting(:git_executable, "git"),
         podman_executable: setting(:podman_executable, "podman"),
         setsid_executable: setsid_executable,
         mkfifo_executable: mkfifo_executable,
         head_executable: head_executable,
         cat_executable: cat_executable,
         sleep_executable: sleep_executable,
         podman_network_command: podman_network_command,
         builder_image: builder_image,
         build_support_dir:
           FileSystem.real_path(Application.app_dir(:biot_node, "priv/build_support")),
         fetch_ca_bundle: fetch_ca_bundle,
         binary_cache_urls: binary_cache_urls,
         binary_cache_keys: binary_cache_keys,
         nixpkgs_repository: setting(:nixpkgs_repository, "https://github.com/NixOS/nixpkgs"),
         nixpkgs_ref: setting(:nixpkgs_ref, "nixos-unstable"),
         command_timeout_ms: command_timeout_ms,
         worker_timeout_ms: worker_timeout_ms,
         command_max_output_bytes: command_max_output_bytes,
         command_max_stderr_bytes: command_max_stderr_bytes,
         runtime_log_max_bytes: runtime_log_max_bytes,
         platform: platform
       }}
    end
  end

  @spec capture_tools(t()) :: Command.capture_tools()
  def capture_tools(%__MODULE__{} = config) do
    %{
      mkfifo: config.mkfifo_executable,
      head: config.head_executable,
      cat: config.cat_executable,
      sleep: config.sleep_executable
    }
  end

  # The moduledoc above is the operator-facing description of this setting.
  defp fetch_ca_bundle do
    case Application.get_env(:biot_node, :fetch_ca_bundle) do
      nil -> {:ok, nil}
      _value -> absolute_path(:fetch_ca_bundle)
    end
  end

  defp absolute_path(key) do
    case Application.get_env(:biot_node, key) do
      value when is_binary(value) ->
        if Path.type(value) == :absolute and Path.expand(value) == value,
          do: {:ok, value},
          else: {:error, {:invalid_config, key}}

      _value ->
        {:error, {:invalid_config, key}}
    end
  end

  defp non_negative_integer(key) do
    case Application.get_env(:biot_node, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _value -> {:error, {:invalid_config, key}}
    end
  end

  defp positive_integer(key) do
    case Application.get_env(:biot_node, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _value -> {:error, {:invalid_config, key}}
    end
  end

  defp uid_range(base, count, limit) do
    if base + count <= limit, do: :ok, else: {:error, {:invalid_config, :uid_range_limit}}
  end

  defp agent_socket_path(runtime_root) do
    length = Paths.agent_socket_path_length(runtime_root)
    limit = Paths.agent_socket_path_limit()

    if length <= limit do
      :ok
    else
      {:error,
       {:invalid_config,
        "BIOT_NODE_RUNTIME_ROOT #{inspect(runtime_root)} produces a #{length}-byte agent " <>
          "socket path; the limit is #{limit} bytes, and the longest runtime root that fits " <>
          "is #{Paths.max_agent_socket_runtime_root_length()} bytes"}}
    end
  end

  # The release pins the builder image by digest, because "the release's trusted image" is a claim
  # about content and a tag is not one.
  defp builder_image do
    case Application.get_env(:biot_node, :builder_image) do
      value when is_binary(value) ->
        if Regex.match?(~r/\A[^@\s]+@sha256:[0-9a-f]{64}\z/, value),
          do: {:ok, value},
          else: {:error, {:invalid_config, :builder_image}}

      _value ->
        {:error, {:invalid_config, :builder_image}}
    end
  end

  defp cache_setting(key) do
    case Application.get_env(:biot_node, key) do
      values when is_list(values) ->
        if Enum.all?(values, &valid_cache_value?/1),
          do: {:ok, values},
          else: {:error, {:invalid_config, key}}

      _values ->
        {:error, {:invalid_config, key}}
    end
  end

  # A value with whitespace would split into two settings in the generated Nix configuration.
  defp valid_cache_value?(value) do
    is_binary(value) and value != "" and not Regex.match?(~r/\s/u, value)
  end

  defp rootless_network_command do
    command = setting(:podman_network_command, "slirp4netns")

    if command in ["pasta", "slirp4netns"] and System.find_executable(command),
      do: {:ok, command},
      else: {:error, {:invalid_config, :podman_network_command}}
  end

  defp executable(key) do
    case Application.get_env(:biot_node, key) do
      value when is_binary(value) ->
        case System.find_executable(value) do
          nil -> {:error, {:executable_not_found, key}}
          path -> {:ok, path}
        end

      _value ->
        {:error, {:invalid_config, key}}
    end
  end

  defp setting(key, default), do: Application.get_env(:biot_node, key, default)
end
