defmodule Biot.Server.Queries.PublicationView do
  @moduledoc "Projects publication rows into public URLs."

  alias Biot.Protocol.Port
  alias Biot.Server.Schema.Publication

  @type t :: %{port: Port.t(), url: String.t()}

  @spec project([Publication.t()], String.t()) :: [t()]
  def project(publications, domain) when is_binary(domain) do
    publications
    |> Enum.sort_by(& &1.port.value)
    |> Enum.map(fn publication ->
      %{port: publication.port, url: "https://#{publication.hostname}.#{domain}"}
    end)
  end
end
