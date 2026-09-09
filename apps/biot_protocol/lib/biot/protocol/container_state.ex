defmodule Biot.Protocol.ContainerState do
  @moduledoc "The observed execution state of a container."

  @type t :: :running | {:exited, non_neg_integer()}
end
