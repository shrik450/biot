defmodule Biot.Server.CommandError do
  @moduledoc "The expected errors returned by server application functions."

  @type field_errors :: %{optional(atom()) => [term()]}
  @type t ::
          :unauthenticated
          | :not_found
          | :forbidden
          | {:invalid_input, field_errors()}
          | {:revision_conflict, pos_integer()}
          | :destroyed
          | :creation_conflict
          | :name_conflict
          | :hostname_conflict
          | :node_disabled
          | :node_abandoned
          | :capacity_exceeded
          | :temporarily_unavailable
end
