ExUnit.start()

Application.put_env(:wallaby, :otp_app, :biot_server)
Application.put_env(:wallaby, :base_url, "http://localhost:4002")

BiotWeb.Browser.configure!()

{:ok, _} = Application.ensure_all_started(:wallaby)
