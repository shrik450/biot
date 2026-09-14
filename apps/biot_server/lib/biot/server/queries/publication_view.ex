defmodule Biot.Server.Queries.PublicationView do
  @moduledoc "Projects publication rows into public URLs."

  alias Biot.Protocol.{Hostname, Port}
  alias Biot.Server.Authorization
  alias Biot.Server.Schema.Publication

  @type t :: %{port: Port.t(), url: String.t()}

  @spec url(Publication.t() | Hostname.t(), String.t()) :: String.t()
  def url(%Publication{hostname: hostname}, domain) when is_binary(domain) do
    format_url(hostname, domain)
  end

  def url(%Hostname{} = hostname, domain) when is_binary(domain) do
    format_url(hostname, domain)
  end

  defp format_url(hostname, domain) do
    "https://#{hostname}.#{domain}"
  end

  @spec visible([Publication.t()], Authorization.role()) :: [Publication.t()]
  def visible(publications, :owner), do: publications

  def visible(publications, {:collaborator, %{view_ports: view_ports}}) do
    visible_ports = MapSet.new(view_ports)
    Enum.filter(publications, &MapSet.member?(visible_ports, &1.port))
  end

  @spec project([Publication.t()], String.t()) :: [t()]
  def project(publications, domain) when is_binary(domain) do
    publications
    |> Enum.sort_by(& &1.port.value)
    |> Enum.map(fn publication ->
      %{port: publication.port, url: url(publication, domain)}
    end)
  end
end
