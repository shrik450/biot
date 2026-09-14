defmodule BiotWeb.PreviewPaths do
  @moduledoc "Owns paths reserved by Biot on every preview host."

  @callback_path "/__biot/callback"

  @spec callback() :: String.t()
  def callback, do: @callback_path
end
