defmodule Biot.Server.ExpirySweepTest do
  use Biot.Server.DataCase, async: false

  alias Biot.Protocol.{CredentialId, SameOriginPath}
  alias Biot.Server.Credentials
  alias Biot.Server.ExpirySweep
  alias Biot.Server.PreviewHandoff
  alias Biot.Server.PreviewHandoff.Finished
  alias Biot.Server.Schema.{Credential, Publication, Session}
  alias Biot.Server.Schema.PreviewHandoff, as: HandoffRow
  alias Biot.Server.Sessions
  alias Biot.Server.TestFixtures
  alias Biot.Server.Tokens

  defp chosen_now, do: DateTime.add(DateTime.utc_now(), 3_600, :second)

  defp insert_control(principal, expires_at) do
    {token, digest} = Tokens.mint()

    session =
      Repo.insert!(%Session{
        id_digest: digest,
        principal_id: principal.id,
        scope: :control,
        expires_at: expires_at
      })

    {token, session}
  end

  defp insert_preview(principal, parent_digest, expires_at) do
    {token, digest} = Tokens.mint()

    session =
      Repo.insert!(%Session{
        id_digest: digest,
        principal_id: principal.id,
        scope: :preview,
        hostname: TestFixtures.hostname(1),
        control_session_digest: parent_digest,
        expires_at: expires_at
      })

    {token, session}
  end

  defp insert_handoff(control_digest, expires_at) do
    {_code, code_digest} = Tokens.mint()
    {_challenge, challenge_digest} = Tokens.mint()

    Repo.insert!(%HandoffRow{
      code_digest: code_digest,
      hostname: TestFixtures.hostname(1),
      control_session_digest: control_digest,
      challenge_digest: challenge_digest,
      return_path: same_origin(),
      expires_at: expires_at
    })
  end

  defp insert_credential(principal, expires_at) do
    {token, digest} = Tokens.mint("biot_")

    credential =
      Repo.insert!(%Credential{
        id: CredentialId.generate(),
        principal_id: principal.id,
        label: "sweep",
        secret_digest: digest,
        expires_at: expires_at
      })

    {token, credential}
  end

  defp set_expiry(schema_row, expires_at) do
    schema_row
    |> Ecto.Changeset.change(expires_at: expires_at)
    |> Repo.update!()
  end

  defp same_origin do
    {:ok, path} = SameOriginPath.parse("/preview/start?step=1")
    path
  end

  defp wait_until(fun, attempts \\ 200)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  describe "Sessions.sweep_expired/1" do
    test "deletes rows at or before now, keeps the row a microsecond later, and it authenticates" do
      principal = TestFixtures.principal(1)
      now = chosen_now()

      {_before_token, _before} = insert_control(principal, DateTime.add(now, -1, :second))
      {_at_token, at_now} = insert_control(principal, now)
      {live_token, live} = insert_control(principal, DateTime.add(now, 1, :microsecond))

      assert Sessions.sweep_expired(now) == 2

      assert Repo.get(Session, at_now.id_digest) == nil
      assert Repo.get(Session, live.id_digest) != nil
      assert {:ok, _} = Sessions.control(live_token)
    end

    test "never sweeps a live row and returns zero when nothing expired" do
      principal = TestFixtures.principal(1)
      now = chosen_now()
      {token, control} = insert_control(principal, DateTime.add(now, 3_600, :second))

      assert Sessions.sweep_expired(now) == 0
      assert Repo.get(Session, control.id_digest) != nil
      assert {:ok, _} = Sessions.control(token)
    end

    test "an expired control session takes its live previews and handoffs with it" do
      principal = TestFixtures.principal(1)
      now = chosen_now()
      later = DateTime.add(now, 3_600, :second)

      {_token, expired_control} = insert_control(principal, now)
      {_preview_token, preview} = insert_preview(principal, expired_control.id_digest, later)
      handoff = insert_handoff(expired_control.id_digest, later)

      {_live_token, live_control} = insert_control(principal, later)

      {_live_preview_token, live_preview} =
        insert_preview(principal, live_control.id_digest, later)

      live_handoff = insert_handoff(live_control.id_digest, later)

      assert Sessions.sweep_expired(now) == 1

      assert Repo.get(Session, expired_control.id_digest) == nil
      assert Repo.get(Session, preview.id_digest) == nil
      assert Repo.get(HandoffRow, handoff.code_digest) == nil

      assert Repo.get(Session, live_control.id_digest) != nil
      assert Repo.get(Session, live_preview.id_digest) != nil
      assert Repo.get(HandoffRow, live_handoff.code_digest) != nil
    end

    test "an expired preview session is deleted on its own expiry" do
      principal = TestFixtures.principal(1)
      now = chosen_now()
      {_token, control} = insert_control(principal, DateTime.add(now, 3_600, :second))
      {_preview_token, preview} = insert_preview(principal, control.id_digest, now)

      assert Sessions.sweep_expired(now) == 1
      assert Repo.get(Session, preview.id_digest) == nil
      assert Repo.get(Session, control.id_digest) != nil
    end
  end

  describe "PreviewHandoff.sweep_expired/1" do
    test "deletes the handoff at now and keeps the one a microsecond later usable" do
      principal = TestFixtures.principal(1)
      node = TestFixtures.node(1)
      {biot, _environment} = TestFixtures.biot(principal, node, 1)
      host = TestFixtures.hostname(1)

      Repo.insert!(%Publication{
        biot_id: biot.id,
        port: TestFixtures.port(3_000),
        hostname: host,
        state: :active
      })

      {:ok, control_token} = Sessions.start_control(principal.id)
      {:ok, authentication} = Sessions.control(control_token)

      expired_challenge = "expired-#{System.unique_integer([:positive])}"
      live_challenge = "live-#{System.unique_integer([:positive])}"

      {:ok, expired_code} =
        PreviewHandoff.begin(
          authentication,
          host,
          Tokens.digest(expired_challenge),
          same_origin()
        )

      {:ok, live_code} =
        PreviewHandoff.begin(authentication, host, Tokens.digest(live_challenge), same_origin())

      now = chosen_now()
      set_expiry(Repo.get!(HandoffRow, Tokens.digest(expired_code)), now)

      set_expiry(
        Repo.get!(HandoffRow, Tokens.digest(live_code)),
        DateTime.add(now, 1, :microsecond)
      )

      assert PreviewHandoff.sweep_expired(now) == 1

      assert Repo.get(HandoffRow, Tokens.digest(expired_code)) == nil
      assert Repo.get(HandoffRow, Tokens.digest(live_code)) != nil

      assert PreviewHandoff.finish(host, expired_code, expired_challenge) ==
               {:error, :unauthenticated}

      assert {:ok, %Finished{}} = PreviewHandoff.finish(host, live_code, live_challenge)
    end

    test "never sweeps a live handoff and returns zero when nothing expired" do
      principal = TestFixtures.principal(1)
      now = chosen_now()
      {_token, control} = insert_control(principal, DateTime.add(now, 3_600, :second))
      handoff = insert_handoff(control.id_digest, DateTime.add(now, 3_600, :second))

      assert PreviewHandoff.sweep_expired(now) == 0
      assert Repo.get(HandoffRow, handoff.code_digest) != nil
    end
  end

  describe "Credentials.sweep_expired/1" do
    test "deletes rows at or before now, keeps the row a microsecond later, and it authenticates" do
      principal = TestFixtures.principal(1)
      now = chosen_now()

      {_before_token, _before} = insert_credential(principal, DateTime.add(now, -1, :second))
      {_at_token, at_now} = insert_credential(principal, now)
      {live_token, live} = insert_credential(principal, DateTime.add(now, 1, :microsecond))

      assert Credentials.sweep_expired(now) == 2

      assert Repo.get(Credential, at_now.id) == nil
      assert Repo.get(Credential, live.id) != nil
      assert {:ok, _} = Credentials.authenticate(live_token)
    end

    test "never sweeps a live credential and returns zero when nothing expired" do
      principal = TestFixtures.principal(1)
      now = chosen_now()
      {token, credential} = insert_credential(principal, DateTime.add(now, 3_600, :second))

      assert Credentials.sweep_expired(now) == 0
      assert Repo.get(Credential, credential.id) != nil
      assert {:ok, _} = Credentials.authenticate(token)
    end
  end

  describe "ExpirySweep.start_link/1" do
    test "returns :ignore when the interval is nil" do
      assert Application.fetch_env!(:biot_server, :expiry_sweep_interval_ms) == nil
      assert ExpirySweep.start_link([]) == :ignore
    end

    test "one run deletes every owner's expired rows" do
      Application.put_env(:biot_server, :expiry_sweep_interval_ms, 20)
      on_exit(fn -> Application.put_env(:biot_server, :expiry_sweep_interval_ms, nil) end)

      principal = TestFixtures.principal(1)
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      later = DateTime.add(DateTime.utc_now(), 3_600, :second)

      {_token, expired_control} = insert_control(principal, past)
      {_preview_token, preview} = insert_preview(principal, expired_control.id_digest, later)
      insert_handoff(expired_control.id_digest, past)
      insert_credential(principal, past)

      {_live_token, live} = insert_control(principal, later)
      expired_handoff = insert_handoff(live.id_digest, past)
      live_handoff = insert_handoff(live.id_digest, later)
      {_live_credential_token, live_credential} = insert_credential(principal, later)

      {:ok, pid} = ExpirySweep.start_link([])
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert wait_until(fn -> Repo.get(Session, expired_control.id_digest) == nil end)
      assert wait_until(fn -> Repo.get(Session, preview.id_digest) == nil end)

      assert wait_until(fn -> Repo.get(HandoffRow, expired_handoff.code_digest) == nil end)

      assert wait_until(fn ->
               Repo.all(HandoffRow) |> Enum.map(& &1.code_digest) == [live_handoff.code_digest]
             end)

      assert wait_until(fn ->
               Repo.all(Credential) |> Enum.map(& &1.id) == [live_credential.id]
             end)

      assert Repo.get(Session, live.id_digest) != nil
    end
  end
end
