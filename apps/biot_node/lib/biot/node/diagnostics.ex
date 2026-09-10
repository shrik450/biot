defmodule Biot.Node.Diagnostics do
  @moduledoc """
  Stores bounded diagnostic files under the node data root and indexes them in the journal.

  Each Biot revision and lifecycle stage has one current entry. The journal keeps entries across
  revisions and destroyed allocations until a server snapshot omits the Biot. Files hold the
  content, while the journal owns identity, truncation, replacement, and retention order.
  """

  alias Biot.Node.Diagnostic
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.FileSystem
  alias Biot.Node.Host.Paths
  alias Biot.Node.Journal
  alias Biot.Protocol.BiotId
  alias Biot.Protocol.CanonicalUuid
  alias Biot.Protocol.Failure
  alias Biot.Protocol.PrivateDiagnosticId

  require Logger

  @doc "Stores one failed stage and returns the private ID carried by its failure."
  @spec put(BiotId.t(), pos_integer(), Failure.stage(), Diagnostic.t()) ::
          PrivateDiagnosticId.t()
  def put(%BiotId{} = biot_id, revision, stage, {content, source_truncated})
      when is_integer(revision) and revision > 0 and is_atom(stage) and is_binary(content) and
             is_boolean(source_truncated) do
    config = Config.from_application!()
    diagnostic_id = mint()
    {stored, entry_truncated} = truncate_head(content, max_entry_bytes())
    path = Paths.diagnostic(config, diagnostic_id)
    :ok = FileSystem.write_atomic(path, stored)

    case Journal.index_diagnostic(
           diagnostic_id,
           biot_id,
           revision,
           stage,
           source_truncated or entry_truncated,
           max_entries_per_biot()
         ) do
      {:ok, stale_ids} ->
        remove_files(config, stale_ids)
        diagnostic_id

      {:error, reason} ->
        remove_files(config, [diagnostic_id])
        raise "could not index diagnostic: #{inspect(reason)}"
    end
  end

  @doc "Returns a bounded diagnostic excerpt and whether capture or this read cut content."
  @spec fetch(PrivateDiagnosticId.t(), pos_integer()) :: {:ok, Diagnostic.t()} | :not_found
  def fetch(%PrivateDiagnosticId{} = diagnostic_id, max_bytes)
      when is_integer(max_bytes) and max_bytes > 0 do
    config = Config.from_application!()

    case Journal.diagnostic(diagnostic_id) do
      nil ->
        :not_found

      truncated ->
        fetch_file(config, diagnostic_id, truncated, max_bytes)
    end
  end

  @doc "Forgets every diagnostic after a server snapshot stops assigning the Biot to this node."
  @spec forget(BiotId.t()) :: :ok
  def forget(%BiotId{} = biot_id) do
    config = Config.from_application!()
    {:ok, diagnostic_ids} = Journal.forget_diagnostics(biot_id)
    remove_files(config, diagnostic_ids)
  end

  defp fetch_file(config, diagnostic_id, stored_truncated, max_bytes) do
    case File.read(Paths.diagnostic(config, diagnostic_id)) do
      {:ok, content} ->
        {content, request_truncated} = truncate_head(content, max_bytes)
        {:ok, {content, stored_truncated or request_truncated}}

      {:error, :enoent} ->
        :not_found

      {:error, reason} ->
        Logger.warning("could not read diagnostic file: #{inspect(reason)}")
        :not_found
    end
  end

  # The index is the authority, so an unlinked stale file cannot keep a diagnostic alive.
  defp remove_files(config, diagnostic_ids) do
    Enum.each(diagnostic_ids, fn diagnostic_id ->
      case File.rm(Paths.diagnostic(config, diagnostic_id)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> Logger.warning("could not remove diagnostic file: #{inspect(reason)}")
      end
    end)

    :ok
  end

  defp truncate_head(content, max_bytes) when byte_size(content) > max_bytes do
    {binary_part(content, 0, max_bytes), true}
  end

  defp truncate_head(content, _max_bytes), do: {content, false}

  defp mint do
    {:ok, diagnostic_id} = PrivateDiagnosticId.parse(CanonicalUuid.generate())
    diagnostic_id
  end

  defp max_entry_bytes do
    Application.fetch_env!(:biot_node, :diagnostic_max_entry_bytes)
  end

  defp max_entries_per_biot do
    Application.fetch_env!(:biot_node, :diagnostic_max_entries_per_biot)
  end
end
