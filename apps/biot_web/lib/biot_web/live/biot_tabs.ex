defmodule BiotWeb.Live.BiotTabs do
  @moduledoc "Owns the route-backed tab vocabulary and loading requests for Biot detail."

  alias Biot.Protocol.BiotId

  @type tab :: :overview | :publications | :access | :secrets | :logs

  @spec from_action(atom() | nil) :: tab()
  def from_action(nil), do: :overview

  def from_action(action) when action in [:overview, :publications, :access, :secrets, :logs],
    do: action

  def from_action(_action), do: :overview

  @spec visible?(map(), tab()) :: boolean()
  def visible?(_view, :publications), do: true
  def visible?(%{role: :owner}, tab) when tab in [:access, :secrets], do: true
  def visible?(%{role: {:collaborator, %{shell: true}}}, :logs), do: true
  def visible?(%{role: :owner}, :logs), do: true
  def visible?(_view, _tab), do: false

  @spec load_messages(tab(), BiotId.t()) :: [tuple()]
  def load_messages(_tab, %BiotId{} = biot_id), do: [{:load_detail, biot_id}]
end
