defmodule BiotWeb.ErrorJSON do
  @moduledoc """
  Renders the API error body for an error raised outside an action, such as an unknown route or a
  crash.

  The body has the `{"error": tag}` shape of `BiotWeb.Api.ErrorResponse`. A crash is `internal`.
  Any other status uses Plug's name for it, so an unknown route is `not_found`.
  """

  alias Plug.Conn.Status

  def render("500.json", _assigns), do: %{"error" => "internal"}

  def render(_template, %{status: status}),
    do: %{"error" => status |> Status.reason_atom() |> Atom.to_string()}
end
