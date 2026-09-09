defmodule BiotWeb.PageController do
  use BiotWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
