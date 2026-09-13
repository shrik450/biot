defmodule Biot.Server.Id do
  @moduledoc "Mints a new canonical protocol ID."

  @spec generate(module()) :: struct()
  def generate(module) do
    {:ok, id} = module.parse(Ecto.UUID.generate())
    id
  end
end
