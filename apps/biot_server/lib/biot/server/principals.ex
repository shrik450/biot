defmodule Biot.Server.Principals do
  @moduledoc "Owns principal identity and last-seen email lookup."

  import Ecto.Query

  alias Biot.Protocol.PrincipalId
  alias Biot.Server.Actor
  alias Biot.Server.CommandError
  alias Biot.Server.Repo
  alias Biot.Server.Schema.Principal

  @spec identify(String.t(), String.t(), %{email: String.t() | nil, name: String.t() | nil}) ::
          {:ok, Principal.t()} | {:error, CommandError.t()}
  def identify(issuer, subject, %{email: email, name: name})
      when is_binary(issuer) and is_binary(subject) and
             (is_binary(email) or is_nil(email)) and (is_binary(name) or is_nil(name)) do
    # Immediate mode takes SQLite write ownership before identity is read.
    Repo.transaction(
      fn ->
        case Repo.one(
               from(principal in Principal,
                 where: principal.issuer == ^issuer and principal.subject == ^subject
               )
             ) do
          nil -> insert(issuer, subject, email, name)
          principal -> update_last_seen(principal, email, name)
        end
      end,
      mode: :immediate
    )
  end

  def identify(_issuer, _subject, _claims) do
    {:error, {:invalid_input, %{identity: [:invalid_format]}}}
  end

  @spec resolve_email(Actor.t() | nil, String.t()) ::
          {:ok, PrincipalId.t()} | {:error, :not_found | :unauthenticated}
  def resolve_email(%Actor{}, email) when is_binary(email) do
    ids =
      from(principal in Principal,
        where: principal.last_seen_email == ^email,
        order_by: [asc: principal.inserted_at],
        limit: 2,
        select: principal.id
      )
      |> Repo.all()

    case ids do
      [principal_id] -> {:ok, principal_id}
      _none_or_ambiguous -> {:error, :not_found}
    end
  end

  def resolve_email(_actor, _email), do: {:error, :unauthenticated}

  defp insert(issuer, subject, email, name) do
    {:ok, principal_id} = PrincipalId.parse(Ecto.UUID.generate())

    %Principal{
      id: principal_id,
      issuer: issuer,
      subject: subject,
      last_seen_email: email,
      last_seen_name: name
    }
    |> Repo.insert()
    |> rollback_on_error()
  end

  defp update_last_seen(principal, email, name) do
    principal
    |> Ecto.Changeset.change(last_seen_email: email, last_seen_name: name)
    |> Repo.update()
    |> rollback_on_error()
  end

  defp rollback_on_error({:ok, principal}), do: principal
  defp rollback_on_error({:error, _changeset}), do: Repo.rollback(:temporarily_unavailable)
end
