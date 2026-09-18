defmodule Biot.Node.GitHostFixture do
  @moduledoc """
  A real Git-over-HTTPS host for the node's Linux integration tests: `git http-backend` behind a TLS
  socket, serving a directory of bare repositories, and optionally refusing every request that does
  not carry one exact `Authorization` header.

  Invariant: the host outlives no test that starts one. It serves from a background thread and its
  main thread does nothing but wait for standard input to close, which is the only shutdown signal
  it ever gets. `Port.close/1` closes the port's pipes but never signals the process, and
  `erl_child_setup` has already put the process in its own session, so a host that waited for a
  signal would survive both the test and the virtual machine that started it.
  """

  import ExUnit.Assertions

  alias Biot.Protocol.RepositorySource

  @enforce_keys [:address, :port, :request_log]
  defstruct [:address, :port, :request_log]

  @type t :: %__MODULE__{address: String.t(), port: pos_integer(), request_log: Path.t()}

  @type option ::
          {:certificate, Path.t()}
          | {:key, Path.t()}
          | {:authorization, String.t()}
          | {:unauthorized_delay_ms, non_neg_integer()}

  @doc """
  Serves every bare repository under `served`, and stops when the calling test ends.

  The caller owns `:certificate` and `:key` because who signed them is often what a test is about:
  one suite needs a certificate from its own authority to exercise a trust bundle, another only
  needs TLS at all. `:authorization` is the single header value the host accepts, and without it
  the host accepts everyone. `:unauthorized_delay_ms` holds a refused request open, which is how a
  test races a credential delivery against a clone that is already in flight.

  The returned `:request_log` names a file with one `authorization absent` or `authorization
  present` line per request, in the directory holding `served`.
  """
  @spec start(Path.t(), [option()]) :: t()
  def start(served, options) do
    certificate = Keyword.fetch!(options, :certificate)
    key = Keyword.fetch!(options, :key)
    authorization = Keyword.get(options, :authorization, "")
    delay = Keyword.get(options, :unauthorized_delay_ms, 0)

    request_log = Path.join(Path.dirname(served), "requests.log")
    File.write!(request_log, "")

    port_number = unused_port()

    server =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 2_048},
        args: [
          "-c",
          source(),
          served,
          Integer.to_string(port_number),
          certificate,
          key,
          authorization,
          request_log,
          Integer.to_string(delay)
        ]
      ])

    assert_receive {^server, {:data, {:eol, "ready"}}}, 10_000

    ExUnit.Callbacks.on_exit(fn -> if Port.info(server), do: Port.close(server) end)

    %__MODULE__{address: address(), port: port_number, request_log: request_log}
  end

  @doc "The source for one bare repository this host serves, named without its `.git` suffix."
  @spec repository_source(t(), String.t()) :: RepositorySource.t()
  def repository_source(%__MODULE__{address: address, port: port}, name) do
    {:ok, source} = RepositorySource.parse("https://#{address}:#{port}/#{name}.git")
    source
  end

  @doc "How many requests reached this host without its authorization."
  @spec unauthorized_count(t()) :: non_neg_integer()
  def unauthorized_count(%__MODULE__{request_log: path}) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.count(&(&1 == "authorization absent"))
  end

  @doc "The address a container reaches this host on, which is never the loopback one."
  @spec address() :: String.t()
  def address do
    {addresses, 0} = System.cmd("hostname", ["-I"], stderr_to_stdout: true)
    addresses |> String.split() |> hd()
  end

  defp unused_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  defp source do
    """
    import http.server, os, ssl, subprocess, sys, threading, time, urllib.parse

    ROOT, PORT, CERT, KEY, EXPECTED, LOG, DELAY = sys.argv[1:8]

    def record(line):
        with open(LOG, "a", encoding="utf-8") as handle:
            handle.write(line + "\\n")

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            return

        def do_GET(self):
            self.serve()

        def do_POST(self):
            self.serve()

        def serve(self):
            authorization = self.headers.get("Authorization")

            if EXPECTED and authorization != EXPECTED:
                record("authorization absent")
                time.sleep(int(DELAY) / 1000.0)
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="biot"')
                self.send_header("Content-Length", "0")
                self.send_header("Connection", "close")
                self.end_headers()
                self.close_connection = True
                return

            record("authorization present")
            self.backend()

        def backend(self):
            parsed = urllib.parse.urlsplit(self.path)
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)
            environment = os.environ.copy()
            environment.update({
                "GIT_PROJECT_ROOT": ROOT,
                "GIT_HTTP_EXPORT_ALL": "1",
                "PATH_INFO": parsed.path,
                "QUERY_STRING": parsed.query,
                "REQUEST_METHOD": self.command,
                "CONTENT_TYPE": self.headers.get("Content-Type", ""),
                "CONTENT_LENGTH": str(length),
                "REMOTE_ADDR": self.client_address[0],
            })
            process = subprocess.run(
                ["git", "http-backend"],
                input=body,
                capture_output=True,
                env=environment,
            )
            headers, payload = process.stdout.split(b"\\r\\n\\r\\n", 1)
            status = 200
            response_headers = []
            for line in headers.decode().split("\\r\\n"):
                name, value = line.split(":", 1)
                if name.lower() == "status":
                    status = int(value.strip().split(" ", 1)[0])
                else:
                    response_headers.append((name, value.strip()))
            self.send_response(status)
            for name, value in response_headers:
                self.send_header(name, value)
            if not any(name.lower() == "content-length" for name, _ in response_headers):
                self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            self.wfile.flush()
            self.close_connection = True

    server = http.server.ThreadingHTTPServer(("0.0.0.0", int(PORT)), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(CERT, KEY)
    server.socket = context.wrap_socket(server.socket, server_side=True)

    threading.Thread(target=server.serve_forever, daemon=True).start()
    print("ready", flush=True)

    # Serving happens on the thread above so that this one can wait here. Closing the port that
    # started this process closes this pipe, and returning from this read ends the process with it.
    sys.stdin.read()
    """
  end
end
