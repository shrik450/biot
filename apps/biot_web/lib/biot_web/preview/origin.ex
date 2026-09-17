defmodule BiotWeb.Preview.Origin do
  @moduledoc """
  The two halves of the preview WebSocket Origin rule.

  A cookie-authenticated upgrade must carry exactly the publication's HTTPS origin. A
  credential-authenticated client may omit `Origin`, but if it sends one it must match. A sibling
  preview origin fails in both cases, because the cookie identifies the user, not the page that
  started the upgrade.
  """

  alias BiotWeb.Preview.Identity

  @spec allowed?(Identity.source(), [String.t()], String.t()) ::
          :ok | {:error, :foreign_origin}
  def allowed?(:credential, [], _expected), do: :ok
  def allowed?(:credential, [origin], expected) when origin == expected, do: :ok
  def allowed?(:cookie, [origin], expected) when origin == expected, do: :ok
  def allowed?(_source, _origins, _expected), do: {:error, :foreign_origin}
end
