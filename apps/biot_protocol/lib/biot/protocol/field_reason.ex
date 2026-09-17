defmodule Biot.Protocol.FieldReason do
  @moduledoc """
  The closed vocabulary of reasons a server may attach to one rejected field.

  A reason is a machine atom; the sentence that shows it belongs to the client that renders it.
  Every emitter builds its `:invalid_input` map through `Biot.Server.CommandError.invalid_input/1`,
  which refuses a reason outside this list, and `BiotWeb.UserMessage` refuses to compile unless it
  has a sentence for every member. So a new reason is either given a sentence or it cannot ship.
  """

  @reasons [
    :missing,
    :invalid_format,
    :out_of_range,
    :too_long,
    :too_short,
    :invalid_value,
    :reserved_name,
    :nul_byte,
    :secret_value_too_large,
    :too_many_layers,
    :repository_url_too_long,
    :source_ref_too_long,
    :embedded_credentials,
    :no_default_node,
    :already_registered,
    :not_future,
    :too_far,
    :unknown_principal,
    :not_requested,
    :not_ready,
    :publication_not_active
  ]

  # The union is built from the list so the type and `all/0` cannot drift apart.
  @typedoc "One reason a server may attach to a rejected field."
  @type t :: unquote(Enum.reduce(@reasons, fn reason, acc -> {:|, [], [reason, acc]} end))

  @doc "Every reason in the vocabulary."
  @spec all() :: [t()]
  def all, do: @reasons

  @doc "Whether `reason` is part of the vocabulary."
  @spec member?(term()) :: boolean()
  def member?(reason), do: reason in @reasons
end
