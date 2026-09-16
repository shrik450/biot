defimpl Phoenix.Param, for: Biot.Protocol.BiotId do
  @moduledoc false

  alias Biot.Protocol.BiotId

  def to_param(%BiotId{} = biot_id), do: BiotId.to_string(biot_id)
end
