defmodule BiotWeb.HealthIntegrationTest do
  use BiotWeb.ConnCase, async: false

  test "answers a healthy check on the control host without a session" do
    conn = get(build_conn(), "/health")

    assert conn.status == 200
    assert json_body(conn) == %{"status" => "ok"}
    assert get_resp_header(conn, "set-cookie") == []
  end

  test "answers a healthy check on a host outside the publication domain" do
    conn = get(%{build_conn() | host: "127.0.0.1"}, "/health")

    assert conn.status == 200
    assert json_body(conn) == %{"status" => "ok"}
  end

  test "leaves a preview host's health path to the preview proxy" do
    conn = get(%{build_conn() | host: "probe.env.test"}, "/health")

    assert conn.status == 404
    refute conn.resp_body =~ "status"
  end
end
