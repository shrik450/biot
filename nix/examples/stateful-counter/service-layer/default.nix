{ pkgs, ... }:

let
  # The HTTP service proves both durable state and access to declared files through one port.
  stateServer = pkgs.writers.writePython3Bin "biot-state-server" { } ''
    import os
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from pathlib import Path

    state_path = Path("value")
    message_path = Path(os.environ["BIOT_CONFIG_ROOT"]) / "files/example/message"


    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            if self.path == "/message":
                value = message_path.read_bytes()
            else:
                value = state_path.read_bytes() if state_path.exists() else b""

            self.send_response(200)
            self.send_header("Content-Length", str(len(value)))
            self.end_headers()
            self.wfile.write(value)

        def do_PUT(self) -> None:
            length = int(self.headers.get("Content-Length", "0"))
            value = self.rfile.read(length)
            state_path.write_bytes(value)
            self.send_response(204)
            self.end_headers()

        def log_message(self, format: str, *args: object) -> None:
            return


    port = int(os.environ["PORT"])
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
  '';
in
{
  biot.environment.BIOT_EXAMPLE = "stateful-counter";
  biot.packages = [ stateServer ];
  biot.services.counter = {
    command = [ "${stateServer}/bin/biot-state-server" ];
    directory = "counter";
    environment.PORT = "8080";
    restart = "on-failure";
  };
}
