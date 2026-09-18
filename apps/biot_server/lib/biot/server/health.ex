defmodule Biot.Server.Health do
  @moduledoc """
  Decides whether the server can do its job right now.

  The database is the one dependency that can fail while the process stays up, so the check runs a
  query against it. The node control listener is deliberately not checked: it is a supervised child
  of this application, so a listener that cannot bind stops the application and one that dies is
  restarted, which means a served request already proves the listener is running. Node connectivity
  is not health either: a server with no node connected is still a working server, and node state
  is reported separately.
  """

  alias Biot.Server.Repo

  @spec check() :: :ok | {:error, :database}
  def check do
    case Repo.query("SELECT 1") do
      {:ok, _result} -> :ok
      {:error, _error} -> {:error, :database}
    end
  rescue
    _error -> {:error, :database}
  catch
    :exit, _reason -> {:error, :database}
  end
end
