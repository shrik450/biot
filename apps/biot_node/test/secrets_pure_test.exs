defmodule Biot.Node.SecretsPureTest do
  use ExUnit.Case, async: true

  import Biot.Node.ReconcileFixtures

  alias Biot.Node.BiotController
  alias Biot.Node.Host.Config
  alias Biot.Node.Host.FetchCredentials
  alias Biot.Node.Host.Git
  alias Biot.Node.Host.Paths
  alias Biot.Node.Host.Worker.Layout
  alias Biot.Node.Reconcile
  alias Biot.Node.RetryState
  alias Biot.Node.SecretRequest
  alias Biot.Protocol.AuthorizationValue
  alias Biot.Protocol.Platform
  alias Biot.Protocol.RepositorySource
  alias Biot.Protocol.SecretName
  alias Biot.Protocol.SecretValue

  # The five phrases Git and a Git server use for "this needs a credential", each carrying the URL
  # or the origin the message is about, which is the only thing that names the source.
  @phrases [
    "fatal: could not read Username for 'https://host.test': terminal prompts disabled",
    "remote: Authentication failed for 'https://host.test/org/repo.git/'",
    "remote: HTTP Basic: Access denied\nfatal: unable to access 'https://host.test/org/repo.git/'",
    "fatal: unable to access 'https://host.test/org/repo.git/': The requested URL returned error: 401",
    "fatal: unable to access 'https://host.test/org/repo.git/': The requested URL returned error: 403"
  ]

  describe "Git.authentication_failure/2" do
    test "output with no authentication phrase is an ordinary failure" do
      repo = source("https://host.test/org/repo.git")

      assert Git.authentication_failure("", [repo]) == :none
      assert Git.authentication_failure("fatal: repository not found", [repo]) == :none

      assert Git.authentication_failure(
               "fatal: unable to access 'https://host.test/org/repo.git/': Could not resolve host",
               [repo]
             ) == :none
    end

    test "each of the five phrases names the one candidate the output mentions" do
      repo = source("https://host.test/org/repo.git")

      for phrase <- @phrases do
        assert Git.authentication_failure(phrase, [repo]) == {:credential_required, repo},
               "expected #{inspect(phrase)} to name the candidate"
      end
    end

    test "a phrase with no candidate named is an ordinary failure" do
      repo = source("https://host.test/org/repo.git")
      other = source("https://elsewhere.test/org/other.git")

      assert Git.authentication_failure("remote: HTTP Basic: Access denied", []) == :none
      assert Git.authentication_failure("remote: HTTP Basic: Access denied", [other]) == :none

      assert Git.authentication_failure(
               "fatal: could not read Username for 'https://nowhere.test': terminal prompts disabled",
               [repo, other]
             ) == :none
    end

    test "two repositories on one origin are told apart by the URL the message names" do
      first = source("https://host.test/org/first.git")
      second = source("https://host.test/org/second.git")

      output =
        "fatal: unable to access 'https://host.test/org/second.git/': The requested URL returned error: 401"

      assert Git.authentication_failure(output, [first, second]) ==
               {:credential_required, second}

      assert Git.authentication_failure(output, [second, first]) ==
               {:credential_required, second}
    end

    test "an origin alone decides only when it names one candidate" do
      first = source("https://host.test/org/first.git")
      second = source("https://host.test/org/second.git")
      output = "fatal: could not read Username for 'https://host.test': terminal prompts disabled"

      assert Git.authentication_failure(output, [first]) == {:credential_required, first}
      assert Git.authentication_failure(output, [first, second]) == :none
      assert Git.authentication_failure(output, [second, first]) == :none
    end

    test "a prefix URL does not steal or block attribution in either order" do
      repo = source("https://host.test/org/repo.git")
      private = source("https://host.test/org/repo-private.git")

      private_output =
        "remote: Authentication failed for 'https://host.test/org/repo-private.git/'"

      assert Git.authentication_failure(private_output, [repo, private]) ==
               {:credential_required, private}

      assert Git.authentication_failure(private_output, [private, repo]) ==
               {:credential_required, private}

      repo_output = "remote: Authentication failed for 'https://host.test/org/repo.git/'"

      assert Git.authentication_failure(repo_output, [repo, private]) ==
               {:credential_required, repo}

      assert Git.authentication_failure(repo_output, [private, repo]) ==
               {:credential_required, repo}
    end

    test "a nested repository path is attributed to the longer candidate" do
      outer = source("https://host.test/org/repo")
      inner = source("https://host.test/org/repo/subrepo")

      output =
        "fatal: unable to access 'https://host.test/org/repo/subrepo/': The requested URL returned error: 403"

      assert Git.authentication_failure(output, [outer, inner]) == {:credential_required, inner}
      assert Git.authentication_failure(output, [inner, outer]) == {:credential_required, inner}
    end

    test "the Nix wrapper form still names the source it failed on" do
      repo = source("https://host.test/org/private.git")

      output = """
      error: Failed to fetch git repository https://host.test/org/private.git : fatal: could not read Username for 'https://host.test': terminal prompts disabled
      """

      assert Git.authentication_failure(output, [repo]) == {:credential_required, repo}
    end

    # The origin fallback compares by substring while the URL match compares by token boundary and
    # unique longest, so an origin that is a prefix of another candidate's origin matches both.
    test "an origin that prefixes another candidate's origin still names one source" do
      ported = source("https://host.test:8443/org/repo.git")
      plain = source("https://host.test/org/repo.git")

      assert RepositorySource.origin(ported) == "https://host.test:8443"
      assert RepositorySource.origin(plain) == "https://host.test"

      ported_output =
        "fatal: could not read Username for 'https://host.test:8443': terminal prompts disabled"

      assert Git.authentication_failure(ported_output, [ported, plain]) ==
               {:credential_required, ported}
    end
  end

  describe "Git.environment/1" do
    test "credentials arrive as a configuration path and never as a value" do
      assert Git.environment(:no_credentials) == [
               {"GIT_CONFIG_GLOBAL", "/dev/null"},
               {"GIT_ALLOW_PROTOCOL", "https"},
               {"GIT_CONFIG_NOSYSTEM", "1"},
               {"GIT_TERMINAL_PROMPT", "0"},
               {"GIT_ASKPASS", ""},
               {"SSH_ASKPASS", ""}
             ]

      assert Git.environment({:credentials, "/biot/fetch-credentials/include.config"}) == [
               {"GIT_CONFIG_GLOBAL", "/biot/fetch-credentials/include.config"},
               {"GIT_ALLOW_PROTOCOL", "https"},
               {"GIT_CONFIG_NOSYSTEM", "1"},
               {"GIT_TERMINAL_PROMPT", "0"},
               {"GIT_ASKPASS", ""},
               {"SSH_ASKPASS", ""}
             ]
    end
  end

  describe "FetchCredentials.fragment/2" do
    test "scopes the header to one URL and refuses redirects" do
      repo = source("https://host.test/org/repo.git")

      assert fragment(repo, "Bearer abc") ==
               "[http \"https://host.test/org/repo.git\"]\n" <>
                 "\textraHeader = \"Authorization: Bearer abc\"\n" <>
                 "\tfollowRedirects = false\n"
    end

    test "quotes and escapes a value that would otherwise change the section" do
      repo = source("https://host.test/org/repo.git")

      for value <- ["a\"b", "a\\b", "a;b", "a#b", "a\"; b # c", "a\\\"b"] do
        rendered = fragment(repo, value)
        escaped = value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

        assert rendered ==
                 "[http \"https://host.test/org/repo.git\"]\n" <>
                   "\textraHeader = \"Authorization: #{escaped}\"\n" <>
                   "\tfollowRedirects = false\n"

        # The value lives inside one quoted Git value, so nothing after it can start a comment or
        # a second setting.
        [_section, header, redirects] = String.split(rendered, "\n", parts: 3)
        assert String.starts_with?(header, "\textraHeader = \"")
        assert String.ends_with?(header, "\"")
        assert redirects == "\tfollowRedirects = false\n"
      end
    end
  end

  describe "FetchCredentials.fragment_name/1" do
    test "is the digest of the URL, stable, and distinct per source" do
      repo = source("https://host.test/org/repo.git")
      other = source("https://host.test/org/other.git")

      expected =
        :sha256
        |> :crypto.hash("https://host.test/org/repo.git")
        |> Base.encode16(case: :lower)
        |> Kernel.<>(".credential")

      assert FetchCredentials.fragment_name(repo) == expected
      assert FetchCredentials.fragment_name(repo) == FetchCredentials.fragment_name(repo)
      assert FetchCredentials.fragment_name(other) != expected
      refute FetchCredentials.fragment_name(repo) =~ "repo"
    end

    test "the include file cannot list itself" do
      repo = source("https://host.test/org/repo.git")
      refute String.ends_with?(FetchCredentials.include_name(), ".credential")
      refute FetchCredentials.fragment_name(repo) == FetchCredentials.include_name()
    end
  end

  describe "RetryState.wait_for_credential/3" do
    test "gives back exactly one attempt and drops the key at one" do
      repo = source("https://host.test/org/repo.git")

      one = RetryState.new(biot_id(), 3) |> RetryState.count_attempt(:resolve)
      assert RetryState.attempts(one, :resolve) == 1

      waited = RetryState.wait_for_credential(one, :resolve, repo)
      assert waited.attempts == %{}
      assert RetryState.attempts(waited, :resolve) == 0
      assert waited.waiting_for == {:fetch_credential, repo}
      assert waited.next_attempt_at == nil
      assert waited.failure == nil

      three =
        RetryState.new(biot_id(), 3)
        |> RetryState.count_attempt(:resolve)
        |> RetryState.count_attempt(:resolve)
        |> RetryState.count_attempt(:resolve)
        |> RetryState.count_attempt(:initialize)

      returned = RetryState.wait_for_credential(three, :resolve, repo)
      assert RetryState.attempts(returned, :resolve) == 2
      assert RetryState.attempts(returned, :initialize) == 1
    end

    test "a stage that spent nothing stays at nothing" do
      repo = source("https://host.test/org/repo.git")
      waited = RetryState.wait_for_credential(RetryState.new(biot_id(), 3), :resolve, repo)

      assert waited.attempts == %{}
      assert RetryState.attempts(waited, :resolve) == 0
    end
  end

  describe "Reconcile.next/3 with a wait" do
    test "blocks a running and a stopped biot and lets a destruction through" do
      repo = source("https://host.test/org/repo.git")
      waiting = {:fetch_credential, repo}

      for desired <- [:running, :stopped] do
        state = state(waiting_for: waiting)

        assert Reconcile.next(spec(state: desired), state, nil) ==
                 {:blocked, {:fetch_credential, repo}}
      end

      destroying = state(waiting_for: waiting, data: {:present, allocation()})

      refute match?(
               {:blocked, {:fetch_credential, _}},
               Reconcile.next(spec(state: :destroyed), destroying, nil)
             )
    end

    test "the wait wins over a recorded failure and loses to the action in flight" do
      repo = source("https://host.test/org/repo.git")

      state =
        state(
          waiting_for: {:fetch_credential, repo},
          failure:
            {1,
             %Biot.Protocol.Failure{
               stage: :resolve,
               code: :resolution_failed,
               retry: :operator,
               message: "stale",
               diagnostic_ref: nil
             }}
        )

      assert Reconcile.next(spec(), state, nil) == {:blocked, {:fetch_credential, repo}}

      current = {:allocate, biot_id()}
      assert {:blocked, {:current_action, ^current}} = Reconcile.next(spec(), state, current)
    end

    test "no wait leaves the decision to the ordinary steps" do
      assert Reconcile.next(spec(), settled(e1()), nil) == :settled
    end
  end

  describe "BiotController.serves_requests?/1" do
    test "answers for every phase constructor" do
      wake = %BiotController.Wake{token: make_ref(), timer: make_ref()}
      task = %Task{ref: make_ref(), pid: self(), owner: self(), mfa: {Biot.Node.Host, :run, 2}}

      effect = %BiotController.Effect{
        action: {:allocate, biot_id()},
        revision: 1,
        task: task
      }

      serving = [
        :idle,
        {:backing_off, wake},
        {:waiting, {:inspection, inspection(:container)}, wake},
        {:settled, wake}
      ]

      waiting = [
        {:recovering, task},
        {:recovery_blocked, wake},
        {:running, effect},
        {:cancelling, effect, wake}
      ]

      for phase <- serving do
        assert BiotController.serves_requests?(phase),
               "expected #{inspect(elem_or(phase))} to serve"
      end

      for phase <- waiting do
        refute BiotController.serves_requests?(phase),
               "expected #{inspect(elem_or(phase))} to wait"
      end
    end
  end

  describe "SecretRequest" do
    test "expiry is exact at the deadline" do
      request = SecretRequest.new("r", :list_secrets, 1_000, self())
      deadline = request.deadline

      refute SecretRequest.expired?(request, deadline - 1)
      refute SecretRequest.expired?(request, deadline)
      assert SecretRequest.expired?(request, deadline + 1)
    end

    test "result kind is derived from the operation alone" do
      repo = source("https://host.test/org/repo.git")
      {:ok, name} = SecretName.parse("DATABASE_URL")
      {:ok, value} = SecretValue.parse("value", 1)
      {:ok, authorization} = AuthorizationValue.parse("Bearer abc", 1)

      cases = [
        {{:deliver_secret, name, value}, :secret},
        {{:remove_secret, name}, :secret},
        {:list_secrets, :secret_list},
        {{:deliver_fetch_credential, repo, authorization}, :fetch_credential},
        {{:remove_fetch_credential, repo}, :fetch_credential}
      ]

      for {operation, kind} <- cases do
        assert SecretRequest.result_kind(operation) == kind
      end
    end

    test "the deadline is this node's own monotonic clock" do
      before = SecretRequest.now()
      request = SecretRequest.new("r", :list_secrets, 5_000, self())

      assert request.deadline >= before + 5_000
      assert request.deadline <= SecretRequest.now() + 5_000
      assert request.reply_to == self()
    end
  end

  describe "Layout per phase" do
    test "only the fetch phase mounts credentials and the operator's certificate authority" do
      config = config("/var/lib/biot", "/etc/biot/fetch-ca.pem")
      biot = biot_id()
      environment = e1()

      fetch = Layout.mounts(config, biot, {:fetch, environment})

      assert {Paths.fetch_credentials(config, biot), "/biot/fetch-credentials", :ro} in fetch
      assert {"/etc/biot/fetch-ca.pem", "/biot/fetch-ca.pem", :ro} in fetch

      for phase <- [{:build, environment, []}, :collect] do
        mounts = Layout.mounts(config, biot, phase)

        refute Enum.any?(mounts, fn {source, _target, _mode} ->
                 source == Paths.fetch_credentials(config, biot)
               end)

        refute Enum.any?(mounts, fn {_source, target, _mode} ->
                 target in ["/biot/fetch-credentials", "/biot/fetch-ca.pem"]
               end)
      end
    end

    test "the fetch mount list is exact" do
      config = config("/var/lib/biot", "/etc/biot/fetch-ca.pem")
      biot = biot_id()
      environment = e1()

      assert Layout.mounts(config, biot, {:fetch, environment}) == [
               {Paths.environment(config, biot, environment), Layout.environment(environment),
                :rw},
               {Paths.build_support(config, biot), "/biot/build-support", :ro},
               {Paths.fetch_credentials(config, biot), "/biot/fetch-credentials", :ro},
               {"/etc/biot/fetch-ca.pem", "/biot/fetch-ca.pem", :ro},
               {Paths.store_root(config, biot), "/biot/store", :rw},
               {Paths.scratch(config, biot), "/build", :rw},
               {Paths.worker_nix_config(config), "/etc/nix/nix.conf", :ro}
             ]
    end

    test "only the fetch phase names the credential include and the certificate authority" do
      config = config("/var/lib/biot", "/etc/biot/fetch-ca.pem")

      fetch = Layout.variables(config, {:fetch, e1()})

      assert {"GIT_CONFIG_GLOBAL", "/biot/fetch-credentials/include.config"} in fetch
      assert {"GIT_SSL_CAINFO", "/biot/fetch-ca.pem"} in fetch
      assert {"NIX_SSL_CERT_FILE", "/biot/fetch-ca.pem"} in fetch

      for phase <- [{:build, e1(), []}, :collect] do
        variables = Layout.variables(config, phase)

        assert {"GIT_CONFIG_GLOBAL", "/dev/null"} in variables
        assert Enum.all?(variables, fn {name, _value} -> name != "GIT_SSL_CAINFO" end)
        assert Enum.all?(variables, fn {name, _value} -> name != "NIX_SSL_CERT_FILE" end)
      end
    end

    test "an operator who names no bundle gets no certificate mount or variable in any phase" do
      config = config("/var/lib/biot", nil)

      for phase <- [{:fetch, e1()}, {:build, e1(), []}, :collect] do
        mounts = Layout.mounts(config, biot_id(), phase)
        variables = Layout.variables(config, phase)

        refute Enum.any?(mounts, fn {_source, target, _mode} -> target == "/biot/fetch-ca.pem" end)

        assert Enum.all?(variables, fn {name, _value} ->
                 name not in ["GIT_SSL_CAINFO", "NIX_SSL_CERT_FILE"]
               end)
      end
    end
  end

  describe "Paths.allocation_directories/2" do
    test "secrets are node-owned and mounted read only; credentials are node-owned and unmounted" do
      config = config("/var/lib/biot", nil)
      biot = biot_id()
      directories = Paths.allocation_directories(config, biot)

      secrets = Enum.find(directories, &(&1.path == Paths.secrets(config, biot)))
      credentials = Enum.find(directories, &(&1.path == Paths.fetch_credentials(config, biot)))

      assert secrets == %{
               path: Paths.secrets(config, biot),
               owner: :node,
               mount: {"/biot/secrets", :ro},
               durable?: true
             }

      assert credentials == %{
               path: Paths.fetch_credentials(config, biot),
               owner: :node,
               mount: nil,
               durable?: true
             }
    end

    test "both directories are required and neither is handed to the allocation's user" do
      config = config("/var/lib/biot", nil)
      biot = biot_id()

      required = Paths.required_directories(config, biot)
      owned = Paths.allocation_owned_directories(config, biot)

      assert Paths.secrets(config, biot) in required
      assert Paths.fetch_credentials(config, biot) in required
      refute Paths.secrets(config, biot) in owned
      refute Paths.fetch_credentials(config, biot) in owned
    end

    test "the credential directory reaches no runtime mount" do
      config = config("/var/lib/biot", nil)
      biot = biot_id()

      refute Enum.any?(Paths.runtime_mounts(config, biot), fn {source, _target, _mode} ->
               source == Paths.fetch_credentials(config, biot)
             end)

      assert {Paths.secrets(config, biot), "/biot/secrets", :ro} in Paths.runtime_mounts(
               config,
               biot
             )
    end
  end

  defp fragment(source, value) do
    {:ok, parsed} = AuthorizationValue.parse(value, 1)
    source |> FetchCredentials.fragment(parsed) |> IO.iodata_to_binary()
  end

  defp source(url) do
    {:ok, source} = RepositorySource.parse(url)
    source
  end

  defp elem_or(phase) when is_tuple(phase), do: elem(phase, 0)
  defp elem_or(phase), do: phase

  defp config(data_root, fetch_ca_bundle) do
    {:ok, platform} = Platform.parse("x86_64-linux")

    struct!(Config,
      data_root: data_root,
      runtime_root: "/run/biot",
      fetch_ca_bundle: fetch_ca_bundle,
      uid_range_base: 100_000,
      uid_range_count: 1_024,
      uid_range_limit: 165_536,
      git_executable: "git",
      podman_executable: "podman",
      setsid_executable: "setsid",
      mkfifo_executable: "mkfifo",
      head_executable: "head",
      cat_executable: "cat",
      sleep_executable: "sleep",
      podman_network_command: "slirp4netns",
      builder_image: "example.test/nix@sha256:#{String.duplicate("a", 64)}",
      build_support_dir: "/source",
      binary_cache_urls: ["https://cache.example.test"],
      binary_cache_keys: ["cache.example.test:key"],
      nixpkgs_repository: "https://github.com/NixOS/nixpkgs",
      nixpkgs_ref: "nixos-unstable",
      command_timeout_ms: 1_000,
      worker_timeout_ms: 2_000,
      command_max_output_bytes: 1_000,
      command_max_stderr_bytes: 1_000,
      runtime_log_max_bytes: 1_000,
      platform: platform
    )
  end
end
