defmodule Biot.Server.SettingsTest do
  use ExUnit.Case, async: true

  alias Biot.Server.DomainName
  alias Biot.Server.Login.Settings

  describe "Login.Settings.parse/4" do
    test "an HTTPS issuer gives settings whose redirect is on the control host" do
      assert {:ok, settings} =
               Settings.parse("https://id.example.test/realm", "biot", "secret", "biot.example")

      assert settings.issuer == "https://id.example.test/realm"
      assert settings.redirect_uri == "https://biot.example/login/callback"
      refute inspect(settings) =~ "secret"
    end

    test "an HTTP issuer is refused, and so is anything that is not an issuer URL" do
      assert Settings.parse("http://id.example.test", "biot", "secret", "biot.example") ==
               {:error, :insecure_issuer}

      for issuer <- ["", "id.example.test", "https://", "ftp://id.example.test"] do
        assert Settings.parse(issuer, "biot", "secret", "biot.example") ==
                 {:error, :invalid_issuer}
      end
    end

    test "an empty client ID or secret is refused" do
      for {id, secret} <- [{"", "secret"}, {"biot", ""}] do
        assert Settings.parse("https://id.example.test", id, secret, "biot.example") ==
                 {:error, :empty_client_credentials}
      end
    end
  end

  describe "DomainName" do
    test "lowercase DNS names parse" do
      for name <- ["example", "biot.example.test", "a-b.c1.example"] do
        assert DomainName.parse(name) == {:ok, name}
      end
    end

    test "anything else is refused" do
      for name <- [
            "",
            ".example",
            "example.",
            "Biot.example",
            "biot..example",
            "biot_1.example",
            "biot.example:443",
            String.duplicate("a.", 127) <> "a",
            nil
          ] do
        assert DomainName.parse(name) == {:error, :invalid_format}
      end
    end

    test "within? matches the domain itself and names under it, never a suffix of a label" do
      assert DomainName.within?("preview.example", "preview.example")
      assert DomainName.within?("biot.preview.example", "preview.example")
      refute DomainName.within?("mypreview.example", "preview.example")
      refute DomainName.within?("biot.example", "preview.example")
    end
  end
end
