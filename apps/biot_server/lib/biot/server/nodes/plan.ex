defmodule Biot.Server.Nodes.Plan do
  @moduledoc "Plans operator node enrollment without reading or writing the database."

  alias Biot.Protocol.NodeId
  alias Biot.Protocol.ParsedList
  alias Biot.Server.Nodes.Registration
  alias Biot.Server.Schema.Node

  @type action ::
          {:insert, Registration.t()}
          | {:update_status, NodeId.t(), Registration.status()}
          | {:update_max_biots, NodeId.t(), pos_integer()}
          | {:disable_omitted, NodeId.t()}
          | {:increment_access_revisions, NodeId.t()}

  @type rejection ::
          {:duplicate_node, NodeId.t()}
          | {:duplicate_registration, NodeId.t()}
          | {:duplicate_peer_identity, NodeId.t()}
          | {:rebinding, NodeId.t()}
          | {:retired_cannot_enable, NodeId.t()}
          | {:retired_cannot_disable, NodeId.t()}
          | {:retirement_blocked, NodeId.t()}

  @spec plan([Node.t()], [Registration.t()], MapSet.t(NodeId.t())) ::
          {:ok, [action()]} | {:error, rejection()}
  def plan(existing_nodes, registrations, nodes_with_allocations)
      when is_list(existing_nodes) and is_list(registrations) do
    with :ok <- validate_configuration(registrations),
         {:ok, configured_actions} <-
           plan_registrations(existing_nodes, registrations, nodes_with_allocations) do
      configured_node_ids = MapSet.new(registrations, & &1.node_id)
      omitted_actions = plan_omissions(existing_nodes, configured_node_ids)

      {:ok, configured_actions ++ omitted_actions}
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
    "node #{NodeId.to_string(node_id)} cannot change its registration or peer identity"
  end

  def message({:retired_cannot_enable, node_id}) do
    "node #{NodeId.to_string(node_id)} is retired and cannot be enabled"
  end

  def message({:retired_cannot_disable, node_id}) do
    "node #{NodeId.to_string(node_id)} is retired and cannot be disabled"
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

    with {:ok, action_groups} <-
           ParsedList.parse(registrations, fn registration ->
             plan_registration(
               existing_by_id,
               existing_by_registration,
               existing_by_peer_identity,
               registration,
               nodes_with_allocations
             )
           end) do
      {:ok, Enum.concat(action_groups)}
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
    Enum.flat_map(existing_nodes, fn
      %Node{status: :enabled, id: node_id} ->
        if MapSet.member?(configured_node_ids, node_id) do
          []
        else
          [
            {:disable_omitted, node_id},
            {:increment_access_revisions, node_id}
          ]
        end

      %Node{} ->
        []
    end)
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
    {:ok, [{:insert, registration}]}
  end

  defp plan_node(node, registration, nodes_with_allocations) do
    with :ok <- validate_binding(node, registration),
         :ok <- validate_transition(node, registration, nodes_with_allocations) do
      {:ok, update_actions(node, registration)}
    end
  end

  defp validate_binding(node, registration) do
    if binding_changed?(node, registration) do
      {:error, {:rebinding, registration.node_id}}
    else
      :ok
    end
  end

  defp validate_transition(%Node{status: :retired, id: node_id}, %{status: :enabled}, _nodes) do
    {:error, {:retired_cannot_enable, node_id}}
  end

  defp validate_transition(%Node{status: :retired, id: node_id}, %{status: :disabled}, _nodes) do
    {:error, {:retired_cannot_disable, node_id}}
  end

  defp validate_transition(%Node{id: node_id}, %{status: :retired}, nodes_with_allocations) do
    if MapSet.member?(nodes_with_allocations, node_id) do
      {:error, {:retirement_blocked, node_id}}
    else
      :ok
    end
  end

  defp validate_transition(%Node{}, %Registration{}, _nodes_with_allocations), do: :ok

  defp binding_used_by_another_node?(existing_by_binding, binding, node_id) do
    case Map.get(existing_by_binding, binding) do
      nil -> false
      %Node{id: existing_node_id} -> existing_node_id != node_id
    end
  end

  defp binding_changed?(node, registration) do
    node.registration != registration.registration_id or
      node.peer_identity != registration.peer_identity
  end

  defp update_actions(node, registration) do
    status_actions =
      if node.status == registration.status do
        []
      else
        [{:update_status, node.id, registration.status}]
      end

    access_actions =
      if node.status == :enabled and registration.status != :enabled do
        [{:increment_access_revisions, node.id}]
      else
        []
      end

    capacity_actions =
      if node.max_biots == registration.max_biots do
        []
      else
        [{:update_max_biots, node.id, registration.max_biots}]
      end

    status_actions ++ access_actions ++ capacity_actions
  end
end
