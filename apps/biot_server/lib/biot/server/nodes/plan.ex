defmodule Biot.Server.Nodes.Plan do
  @moduledoc "Plans operator node enrollment without reading or writing the database."

  alias Biot.Protocol.NodeId
  alias Biot.Protocol.ParsedList
  alias Biot.Server.Nodes.Registration
  alias Biot.Server.Nodes.Status
  alias Biot.Server.Schema.Node

  @enforce_keys [:writes, :close_connections]
  defstruct [:writes, :close_connections]

  @type action ::
          {:insert, Registration.t()}
          | {:update_status, NodeId.t(), Registration.status()}
          | {:update_max_biots, NodeId.t(), pos_integer()}
          | {:replace_peer_identity, NodeId.t(), String.t()}
          | {:increment_access_revisions, NodeId.t()}
          | {:fail_operations, NodeId.t()}

  @type t :: %__MODULE__{
          writes: [action()],
          close_connections: [NodeId.t()]
        }

  @type rejection ::
          {:duplicate_node, NodeId.t()}
          | {:duplicate_registration, NodeId.t()}
          | {:duplicate_peer_identity, NodeId.t()}
          | {:rebinding, NodeId.t()}
          | {:terminal_node_locked, NodeId.t(), :retired | :abandoned}
          | {:retirement_blocked, NodeId.t()}

  @spec plan([Node.t()], [Registration.t()], MapSet.t(NodeId.t())) ::
          {:ok, t()} | {:error, rejection()}
  def plan(existing_nodes, registrations, nodes_with_allocations)
      when is_list(existing_nodes) and is_list(registrations) do
    with :ok <- validate_configuration(registrations),
         {:ok, configured_plan} <-
           plan_registrations(existing_nodes, registrations, nodes_with_allocations) do
      configured_node_ids = MapSet.new(registrations, & &1.node_id)
      omitted_plan = plan_omissions(existing_nodes, configured_node_ids)

      {:ok, combine_plans([configured_plan, omitted_plan])}
    end
  end

  @spec message(rejection()) :: String.t()
  def message({:duplicate_node, node_id}) do
    "node #{NodeId.to_string(node_id)} appears more than once in configuration"
  end

  def message({:duplicate_registration, node_id}) do
    "node #{NodeId.to_string(node_id)} reuses a registration ID in configuration"
  end

  def message({:duplicate_peer_identity, node_id}) do
    "node #{NodeId.to_string(node_id)} reuses a peer identity in configuration"
  end

  def message({:rebinding, node_id}) do
    "node #{NodeId.to_string(node_id)} cannot change its registration ID or reuse another node's identity"
  end

  def message({:terminal_node_locked, node_id, status}) do
    "node #{NodeId.to_string(node_id)} is #{status} and cannot change"
  end

  def message({:retirement_blocked, node_id}) do
    "node #{NodeId.to_string(node_id)} cannot retire while assigned biot allocations are not known absent"
  end

  defp validate_configuration(registrations) do
    with :ok <- validate_unique(registrations, & &1.node_id, :duplicate_node),
         :ok <- validate_unique(registrations, & &1.registration_id, :duplicate_registration) do
      validate_unique(registrations, & &1.peer_identity, :duplicate_peer_identity)
    end
  end

  defp validate_unique(registrations, key_fun, rule) do
    case Enum.find_value(Enum.group_by(registrations, key_fun), fn
           {_key, [%{node_id: node_id}, _ | _]} -> {:error, {rule, node_id}}
           _group -> nil
         end) do
      nil -> :ok
      rejection -> rejection
    end
  end

  defp plan_registrations(existing_nodes, registrations, nodes_with_allocations) do
    existing_by_id = Map.new(existing_nodes, &{&1.id, &1})
    existing_by_registration = Map.new(existing_nodes, &{&1.registration, &1})
    existing_by_peer_identity = Map.new(existing_nodes, &{&1.peer_identity, &1})

    with {:ok, plans} <-
           ParsedList.parse(registrations, fn registration ->
             plan_registration(
               existing_by_id,
               existing_by_registration,
               existing_by_peer_identity,
               registration,
               nodes_with_allocations
             )
           end) do
      {:ok, combine_plans(plans)}
    end
  end

  defp plan_registration(
         existing_by_id,
         existing_by_registration,
         existing_by_peer_identity,
         registration,
         nodes_with_allocations
       ) do
    with :ok <-
           validate_available_binding(
             existing_by_registration,
             existing_by_peer_identity,
             registration
           ) do
      existing_by_id
      |> Map.get(registration.node_id)
      |> plan_node(registration, nodes_with_allocations)
    end
  end

  defp plan_omissions(existing_nodes, configured_node_ids) do
    existing_nodes
    |> Enum.map(fn node -> plan_omission(node, configured_node_ids) end)
    |> combine_plans()
  end

  defp plan_omission(node, configured_node_ids) do
    if MapSet.member?(configured_node_ids, node.id), do: empty_plan(), else: disable(node)
  end

  defp disable(%Node{} = node) do
    if Status.serves_access?(node.status) do
      %__MODULE__{
        writes: [
          {:update_status, node.id, :disabled},
          {:increment_access_revisions, node.id}
        ],
        close_connections: [node.id]
      }
    else
      empty_plan()
    end
  end

  defp validate_available_binding(
         existing_by_registration,
         existing_by_peer_identity,
         registration
       ) do
    registration_id_used? =
      binding_used_by_another_node?(
        existing_by_registration,
        registration.registration_id,
        registration.node_id
      )

    peer_identity_used? =
      binding_used_by_another_node?(
        existing_by_peer_identity,
        registration.peer_identity,
        registration.node_id
      )

    if registration_id_used? or peer_identity_used? do
      {:error, {:rebinding, registration.node_id}}
    else
      :ok
    end
  end

  defp plan_node(nil, registration, _nodes_with_allocations) do
    {:ok, %__MODULE__{writes: [{:insert, registration}], close_connections: []}}
  end

  defp plan_node(node, registration, nodes_with_allocations) do
    with :ok <- validate_registration_binding(node, registration),
         :ok <- validate_transition(node, registration, nodes_with_allocations) do
      {:ok, plan_update(node, registration)}
    end
  end

  defp validate_registration_binding(node, registration) do
    if node.registration != registration.registration_id do
      {:error, {:rebinding, registration.node_id}}
    else
      :ok
    end
  end

  defp validate_transition(
         %Node{} = node,
         registration,
         nodes_with_allocations
       ) do
    if Status.terminal?(node.status),
      do: validate_terminal_repeat(node, registration),
      else: validate_open_transition(node, registration, nodes_with_allocations)
  end

  defp validate_terminal_repeat(%Node{id: node_id, status: status} = node, registration) do
    if same_configuration?(node, registration) do
      :ok
    else
      {:error, {:terminal_node_locked, node_id, status}}
    end
  end

  defp validate_open_transition(
         %Node{id: node_id},
         %{status: :retired},
         nodes_with_allocations
       ) do
    if MapSet.member?(nodes_with_allocations, node_id) do
      {:error, {:retirement_blocked, node_id}}
    else
      :ok
    end
  end

  defp validate_open_transition(%Node{}, %Registration{}, _nodes_with_allocations), do: :ok

  defp binding_used_by_another_node?(existing_by_binding, binding, node_id) do
    case Map.get(existing_by_binding, binding) do
      nil -> false
      %Node{id: existing_node_id} -> existing_node_id != node_id
    end
  end

  defp same_configuration?(node, registration) do
    node.peer_identity == registration.peer_identity and
      node.status == registration.status and
      node.max_biots == registration.max_biots
  end

  defp plan_update(node, registration) do
    writes =
      Enum.flat_map(
        [
          &status_action/2,
          &access_action/2,
          &operation_action/2,
          &identity_action/2,
          &capacity_action/2
        ],
        & &1.(node, registration)
      )

    close_connections =
      [&identity_connection/2, &status_connection/2]
      |> Enum.flat_map(& &1.(node, registration))
      |> Enum.uniq()

    %__MODULE__{writes: writes, close_connections: close_connections}
  end

  defp status_action(%Node{status: status}, %Registration{status: status}), do: []

  defp status_action(node, registration),
    do: [{:update_status, node.id, registration.status}]

  defp access_action(node, registration) do
    if revokes_access?(node.status, registration.status),
      do: [{:increment_access_revisions, node.id}],
      else: []
  end

  defp revokes_access?(current, requested) do
    (Status.serves_access?(current) and not Status.serves_access?(requested)) or
      (Status.written_off?(requested) and not Status.written_off?(current))
  end

  defp operation_action(node, registration) do
    if Status.written_off?(registration.status) and not Status.written_off?(node.status),
      do: [{:fail_operations, node.id}],
      else: []
  end

  defp identity_action(%Node{peer_identity: identity}, %Registration{peer_identity: identity}),
    do: []

  defp identity_action(node, registration),
    do: [{:replace_peer_identity, node.id, registration.peer_identity}]

  defp capacity_action(%Node{max_biots: max_biots}, %Registration{max_biots: max_biots}),
    do: []

  defp capacity_action(node, registration),
    do: [{:update_max_biots, node.id, registration.max_biots}]

  defp identity_connection(
         %Node{peer_identity: identity},
         %Registration{peer_identity: identity}
       ),
       do: []

  defp identity_connection(node, %Registration{}), do: [node.id]

  defp status_connection(%Node{status: status}, %Registration{status: status}), do: []

  defp status_connection(node, registration) do
    if Status.serves_access?(registration.status), do: [], else: [node.id]
  end

  defp combine_plans(plans) do
    %__MODULE__{
      writes: Enum.flat_map(plans, & &1.writes),
      close_connections: plans |> Enum.flat_map(& &1.close_connections) |> Enum.uniq()
    }
  end

  defp empty_plan, do: %__MODULE__{writes: [], close_connections: []}
end
