defmodule Biot.Node.EnvironmentBundle do
  @moduledoc "The immutable launch paths produced by one prepared environment artifact."

  alias Biot.Node.StorePath
  alias Biot.Protocol.StrictMap

  @format 1
  @fields [
    "format",
    "closure_root",
    "rootfs",
    "entrypoint",
    "shell_entrypoint",
    "environment_file",
    "config_root"
  ]

  @enforce_keys [
    :closure_root,
    :rootfs,
    :entrypoint,
    :shell_entrypoint,
    :environment_file,
    :config_root
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          closure_root: StorePath.t(),
          rootfs: StorePath.t(),
          entrypoint: StorePath.t(),
          shell_entrypoint: StorePath.t(),
          environment_file: StorePath.t(),
          config_root: StorePath.t()
        }

  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_format | :unsupported_format}
  def parse(%{"format" => @format} = value) do
    with {:ok, _value} <- StrictMap.fetch_exact(value, @fields),
         {:ok, closure_root} <- StorePath.parse(value["closure_root"]),
         {:ok, rootfs} <- StorePath.parse(value["rootfs"]),
         {:ok, entrypoint} <- StorePath.parse(value["entrypoint"]),
         {:ok, shell_entrypoint} <- StorePath.parse(value["shell_entrypoint"]),
         {:ok, environment_file} <- StorePath.parse(value["environment_file"]),
         {:ok, config_root} <- StorePath.parse(value["config_root"]) do
      {:ok,
       %__MODULE__{
         closure_root: closure_root,
         rootfs: rootfs,
         entrypoint: entrypoint,
         shell_entrypoint: shell_entrypoint,
         environment_file: environment_file,
         config_root: config_root
       }}
    else
      _error -> {:error, :invalid_format}
    end
  end

  def parse(%{"format" => format}) when is_number(format), do: {:error, :unsupported_format}

  def parse(_value), do: {:error, :invalid_format}
end
