defmodule BiotWeb.Api.BearerHeader do
  @moduledoc """
  Reads the bearer token from a request's `authorization` header values.

  A request has a token only when it carries exactly one header holding exactly one `Bearer`
  token. Two headers, or two credentials in one header, give no token.
  """

  @spec token([String.t()]) :: {:ok, String.t()} | :error
  def token([value]) do
    # The token is RFC 7235 token68, and the scheme name is case-insensitive.
    case Regex.run(~r/\ABearer +([A-Za-z0-9\-._~+\/]+=*)\z/i, value, capture: :all_but_first) do
      [token] -> {:ok, token}
      nil -> :error
    end
  end

  def token(_values), do: :error
end
