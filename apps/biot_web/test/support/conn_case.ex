defmodule BiotWeb.ConnCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  import Plug.Conn
  import Phoenix.ConnTest, except: [build_conn: 0]

  alias Biot.Server.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint BiotWeb.Endpoint

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest, except: [build_conn: 0]
      import BiotWeb.ConnCase

      @endpoint BiotWeb.Endpoint
    end
  end

  setup tags do
    owner = Sandbox.start_owner!(Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    :ok
  end

  @doc """
  Builds a conn on the control host.

  `Phoenix.ConnTest.build_conn/0` defaults the host to `www.example.com`, which is not the control
  host, so `BiotWeb.Plugs.HostDispatch` correctly answers it with the 404 page. A real browser
  arrives on the control host, so the suite does too.
  """
  @spec build_conn() :: Plug.Conn.t()
  def build_conn do
    %{Phoenix.ConnTest.build_conn() | host: Application.fetch_env!(:biot_server, :control_host)}
  end

  @spec json_request(Plug.Conn.t(), atom(), String.t(), map() | nil) :: Plug.Conn.t()
  def json_request(conn, method, path, body \\ nil) do
    conn = put_req_header(conn, "content-type", "application/json")

    case {method, body} do
      {:get, nil} -> get(conn, path)
      {:delete, nil} -> delete(conn, path)
      {:delete, body} -> delete(conn, path, Jason.encode!(body))
      {:post, body} -> post(conn, path, Jason.encode!(body))
      {:put, body} -> put(conn, path, Jason.encode!(body))
    end
  end

  @spec api_conn(String.t() | nil) :: Plug.Conn.t()
  def api_conn(nil), do: Plug.Test.init_test_session(build_conn(), %{})

  def api_conn(token) when is_binary(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> Plug.Test.init_test_session(%{})
  end

  @spec json_body(Plug.Conn.t()) :: term()
  def json_body(conn), do: Jason.decode!(conn.resp_body)

  @spec cookie_value(Plug.Conn.t(), String.t()) :: String.t() | nil
  def cookie_value(conn, name) do
    conn
    |> get_resp_header("set-cookie")
    |> Enum.find_value(fn header ->
      case Regex.run(~r/(?:\A|;\s*)#{Regex.escape(name)}=([^;]*)/, header,
             capture: :all_but_first
           ) do
        [value] -> value
        nil -> nil
      end
    end)
  end
end
