ExUnit.start()

Application.put_env(:wallaby, :otp_app, :biot_server)

capabilities =
  Wallaby.Chrome.default_capabilities()
  |> update_in([:chromeOptions, :args], fn args ->
    args ++ ["--host-resolver-rules=MAP *.env.test 127.0.0.1"]
  end)
  |> put_in([:chromeOptions, :binary], "/usr/bin/chromium-browser")

Application.put_env(:wallaby, :chromedriver,
  path: "/usr/bin/chromedriver",
  binary: "/usr/bin/chromium-browser",
  capabilities: capabilities
)

Application.put_env(:wallaby, :base_url, "http://localhost:4002")

{:ok, _} = Application.ensure_all_started(:wallaby)
