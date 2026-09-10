defmodule Biot.Node.Diagnostic do
  @moduledoc "A bounded diagnostic and whether its source or storage cut any bytes."

  @type t :: {binary(), boolean()}

  @spec text(binary()) :: t()
  def text(content) when is_binary(content), do: {content, false}
end
