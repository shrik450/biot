defmodule BiotWeb.Api.Response do
  @moduledoc """
  Maps a successful command result to its HTTP status, headers, and JSON body.

  An `Accepted` change returns 202 with a `location` header for its operation. A lifecycle
  `Unchanged` result returns 200. Both policy results return 200 with the access revision and the
  enforcement state. A newly added SSH key returns 201 with the key. A bare `:ok`, which secret,
  fetch credential, credential, and SSH key changes return, gives 204 with no body. This module is
  the only place that builds the operation path.
  """

  alias Biot.Server.Biots
  alias Biot.Server.Biots.Accepted
  alias Biot.Server.Policy
  alias Biot.Server.Queries.SshKeyView
  alias BiotWeb.Api.Json

  @type t :: {pos_integer(), [{String.t(), String.t()}], %{String.t() => term()} | nil}

  @spec build(
          Accepted.t()
          | Biots.Unchanged.t()
          | Policy.Applied.t()
          | Policy.Unchanged.t()
          | SshKeyView.t()
          | :ok
        ) :: t()
  def build(%Accepted{} = accepted) do
    {202, [{"location", "/api/operations/#{accepted.operation_id}"}],
     %{
       "operation_id" => to_string(accepted.operation_id),
       "biot_id" => to_string(accepted.biot_id),
       "revision" => accepted.revision
     }}
  end

  def build(%Biots.Unchanged{} = unchanged) do
    {200, [], %{"biot_id" => to_string(unchanged.biot_id), "revision" => unchanged.revision}}
  end

  def build(%Policy.Applied{} = applied), do: {200, [], policy("applied", applied)}
  def build(%Policy.Unchanged{} = unchanged), do: {200, [], policy("unchanged", unchanged)}
  def build(%SshKeyView{} = key), do: {201, [], Json.encode(key)}
  def build(:ok), do: {204, [], nil}

  defp policy(result, change) do
    %{
      "result" => result,
      "biot_id" => to_string(change.biot_id),
      "access_revision" => change.access_revision,
      "enforcement" => Json.enforcement(change.enforcement)
    }
  end
end
