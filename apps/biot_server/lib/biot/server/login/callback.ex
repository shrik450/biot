defmodule Biot.Server.Login.Callback do
  @moduledoc "Parses and checks the parameters returned by an OIDC provider."

  @spec parse(map(), String.t()) :: {:ok, String.t()} | :error
  def parse(callback_params, expected_state)
      when is_map(callback_params) and is_binary(expected_state) do
    if Map.has_key?(callback_params, "error") do
      :error
    else
      check_state(callback_params["state"], callback_params["code"], expected_state)
    end
  end

  def parse(_callback_params, _expected_state), do: :error

  defp check_state(state, code, expected_state)
       when is_binary(state) and is_binary(code) do
    if byte_size(state) == byte_size(expected_state) and
         :crypto.hash_equals(state, expected_state) do
      {:ok, code}
    else
      :error
    end
  end

  defp check_state(_state, _code, _expected_state), do: :error
end
