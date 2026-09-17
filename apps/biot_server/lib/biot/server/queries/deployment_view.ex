defmodule Biot.Server.Queries.DeploymentView do
  @moduledoc "The public connection settings advertised by this server."

  @enforce_keys [:publication_domain, :ssh]
  defstruct [:publication_domain, :ssh, :ssh_host_keys]

  @type ssh_host_key :: %{
          type: String.t(),
          public_key: String.t(),
          fingerprint: String.t()
        }

  @type t :: %__MODULE__{
          publication_domain: String.t(),
          ssh: %{host: String.t(), port: pos_integer()},
          ssh_host_keys: [ssh_host_key()] | nil
        }
end
