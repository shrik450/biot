defmodule Biot.Node.Host.Config do
  @moduledoc "The parsed operator settings used by host inspection and effects."

  alias Biot.Node.Host.Command
  alias Biot.Protocol.Platform

  @enforce_keys [
    :data_root,
    :uid_range_base,
    :uid_range_count,
    :uid_range_limit,
    :git_executable,
    :nix_executable,
    :nix_instantiate_executable,
    :podman_executable,
    :setsid_executable,
    :mkfifo_executable,
    :head_executable,
    :cat_executable,
    :sleep_executable,
    :podman_network_command,
    :nix_build_file,
    :nix_pin_file,
    :nixpkgs_repository,
    :nixpkgs_ref,
    :command_timeout_ms,
    :command_max_output_bytes,
    :command_max_stderr_bytes,
    :runtime_log_max_bytes,
    :platform
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          data_root: String.t(),
          uid_range_base: non_neg_integer(),
          uid_range_count: pos_integer(),
          uid_range_limit: pos_integer(),
          git_executable: String.t(),
          nix_executable: String.t(),
          nix_instantiate_executable: String.t(),
          podman_executable: String.t(),
          setsid_executable: String.t(),
          mkfifo_executable: String.t(),
          head_executable: String.t(),
          cat_executable: String.t(),
          sleep_executable: String.t(),
          podman_network_command: String.t(),
          nix_build_file: String.t(),
          nix_pin_file: String.t(),
          nixpkgs_repository: String.t(),
          nixpkgs_ref: String.t(),
          command_timeout_ms: pos_integer(),
          command_max_output_bytes: pos_integer(),
          command_max_stderr_bytes: pos_integer(),
          runtime_log_max_bytes: pos_integer(),
          platform: Platform.t()
        }

  @spec from_application() :: {:ok, t()} | {:error, term()}
  def from_application do
    with {:ok, platform} <- Platform.current(),
         {:ok, data_root} <- absolute_path(:data_root),
         {:ok, uid_range_base} <- non_negative_integer(:uid_range_base),
         {:ok, uid_range_count} <- positive_integer(:uid_range_count),
         {:ok, uid_range_limit} <- positive_integer(:uid_range_limit),
         :ok <- uid_range(uid_range_base, uid_range_count, uid_range_limit),
         {:ok, nix_build_file} <- absolute_path(:nix_build_file),
         {:ok, nix_pin_file} <- absolute_path(:nix_pin_file),
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
         {:ok, runtime_log_max_bytes} <- positive_integer(:runtime_log_max_bytes) do
      {:ok,
       %__MODULE__{
         data_root: data_root,
         uid_range_base: uid_range_base,
         uid_range_count: uid_range_count,
         uid_range_limit: uid_range_limit,
         git_executable: setting(:git_executable, "git"),
         nix_executable: setting(:nix_executable, "nix"),
         nix_instantiate_executable: setting(:nix_instantiate_executable, "nix-instantiate"),
         podman_executable: setting(:podman_executable, "podman"),
         setsid_executable: setsid_executable,
         mkfifo_executable: mkfifo_executable,
         head_executable: head_executable,
         cat_executable: cat_executable,
         sleep_executable: sleep_executable,
         podman_network_command: podman_network_command,
         nix_build_file: nix_build_file,
         nix_pin_file: nix_pin_file,
         nixpkgs_repository: setting(:nixpkgs_repository, "https://github.com/NixOS/nixpkgs"),
         nixpkgs_ref: setting(:nixpkgs_ref, "nixos-unstable"),
         command_timeout_ms: command_timeout_ms,
         command_max_output_bytes: command_max_output_bytes,
         command_max_stderr_bytes: command_max_stderr_bytes,
         runtime_log_max_bytes: runtime_log_max_bytes,
         platform: platform
       }}
    end
  end

  # A complete host config is a precondition for every node process because boot validates it.
  @spec from_application!() :: t()
  def from_application! do
    case from_application() do
      {:ok, config} -> config
      {:error, reason} -> raise "invalid host config: #{inspect(reason)}"
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
