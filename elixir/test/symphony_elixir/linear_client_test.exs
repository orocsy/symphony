defmodule SymphonyElixir.LinearClientTest do
  use SymphonyElixir.TestSupport

  setup do
    proxy_env_names = ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"]
    previous_proxy_env = Map.new(proxy_env_names, &{&1, System.get_env(&1)})

    Enum.each(proxy_env_names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous_proxy_env, fn {name, value} -> restore_env(name, value) end)
    end)

    :ok
  end

  test "linear connect options honor HTTP proxy environment" do
    System.put_env("HTTPS_PROXY", "http://127.0.0.1:18888")

    connect_options = Client.connect_options_for_test()

    assert Keyword.fetch!(connect_options, :timeout) == 60_000
    assert Keyword.fetch!(connect_options, :proxy) == {:http, "127.0.0.1", 18_888, []}
    assert Keyword.fetch!(connect_options, :transport_opts)[:cacertfile]
  end

  test "linear connect options support proxy credentials" do
    System.put_env("HTTP_PROXY", "http://agent:secret@proxy.example.test:8080")

    connect_options = Client.connect_options_for_test()

    assert Keyword.fetch!(connect_options, :proxy) == {:http, "proxy.example.test", 8080, []}

    assert Keyword.fetch!(connect_options, :proxy_headers) == [
             {"proxy-authorization", "Basic " <> Base.encode64("agent:secret")}
           ]
  end

  test "linear connect options ignore unsupported proxy schemes" do
    System.put_env("HTTPS_PROXY", "socks5://127.0.0.1:1080")

    connect_options = Client.connect_options_for_test()

    refute Keyword.has_key?(connect_options, :proxy)
    assert Keyword.fetch!(connect_options, :timeout) == 60_000
  end
end
