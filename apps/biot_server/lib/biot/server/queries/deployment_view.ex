defmodule Biot.Server.Queries.DeploymentView do
  @moduledoc "The public connection settings advertised by this server."

  @enforce_keys [:publication_domain, :ssh]
  defstruct [:publication_domain, :ssh]

  @type t :: %__MODULE__{
          publication_domain: String.t(),
          ssh: %{host: String.t(), port: pos_integer()}
        }
end
