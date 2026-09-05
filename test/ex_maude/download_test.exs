defmodule ExMaude.DownloadTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "streams a complete response into a file", %{tmp_dir: dir} do
    url = serve("HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nhello world")
    path = Path.join(dir, "download")
    assert :ok = ExMaude.Download.fetch(url, path, timeout: 1000, max_bytes: 11)
    assert File.read!(path) == "hello world"
  end

  test "rejects an oversized chunk before the response completes", %{tmp_dir: dir} do
    url = serve("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nB\r\nhello world\r\n")
    path = Path.join(dir, "download")
    assert {:error, :too_large} = ExMaude.Download.fetch(url, path, timeout: 1000, max_bytes: 10)
    refute File.exists?(path)
  end

  test "enforces a deadline on stalled bodies and deletes partial files", %{tmp_dir: dir} do
    url = serve("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\npartial")
    path = Path.join(dir, "download")
    started = System.monotonic_time(:millisecond)
    assert {:error, _} = ExMaude.Download.fetch(url, path, timeout: 100, max_bytes: 100)
    assert System.monotonic_time(:millisecond) - started < 1000
    refute File.exists?(path)
  end

  test "returns redirects without buffering their bodies", %{tmp_dir: dir} do
    url = serve("HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 999999\r\n\r\n")

    assert {:redirect, "/next"} =
             ExMaude.Download.fetch(url, Path.join(dir, "download"), timeout: 1000, max_bytes: 10)
  end

  defp serve(response) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _} = :gen_tcp.recv(socket, 0, 1000)
        :ok = :gen_tcp.send(socket, response)
        receive do: (:stop -> :gen_tcp.close(socket))
      end)

    on_exit(fn ->
      send(server, :stop)
      :gen_tcp.close(listener)
    end)

    "http://127.0.0.1:#{port}/archive"
  end
end
