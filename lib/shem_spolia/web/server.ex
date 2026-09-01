defmodule ShemSpolia.Web.Server do
  @moduledoc """
  A minimal HTTP/1.1 server over `:gen_tcp` — the demo surface for the auditor.

  Deliberately not Bandit/Plug: the whole claim of `shem_audit` is one file, no
  toolchain, no runtime. The WebUI is an optional demo, and coupling an optional
  demo to the shipping artifact's dependency set is a bad trade. The surface here
  is small enough to own: loopback only, single reader, GET static + a JSON API +
  one SSE stream.

  Not a general-purpose server. No TLS, no keep-alive, no chunked *request*
  bodies, no multipart. One connection = one request = one response, except for
  `/api/stream`, which holds the socket open and writes `text/event-stream`
  frames until the client disconnects.

  Binds `127.0.0.1` and refuses anything else: see `bind_address/1`. A tamper-
  evidence tool that listens on `0.0.0.0` by accident is a liability, so the
  loopback default is enforced in code rather than documented in a README.
  """

  require Logger

  alias ShemSpolia.Web.{Assets, Router}

  @default_port 4180
  @max_request_bytes 1_048_576
  @read_timeout 15_000

  @spec start(keyword()) :: {:ok, :inet.port_number()} | {:error, term()}
  def start(opts \\ []) do
    port = Keyword.get(opts, :port, @default_port)
    addr = bind_address(Keyword.get(opts, :host, "127.0.0.1"))

    listen_opts = [
      :binary,
      packet: :raw,
      active: false,
      reuseaddr: true,
      backlog: 64,
      ip: addr
    ]

    case :gen_tcp.listen(port, listen_opts) do
      {:ok, socket} ->
        {:ok, actual} = :inet.port(socket)
        spawn_link(fn -> accept_loop(socket) end)
        {:ok, actual}

      {:error, reason} ->
        {:error, {:listen_failed, port, reason}}
    end
  end

  @doc """
  Only loopback. `--host` exists so you can pick between IPv4 and IPv6 loopback,
  not so you can expose the auditor to a network. Anything else is a caller bug
  and fails loudly at bind time rather than silently listening in public.
  """
  @spec bind_address(String.t()) :: :inet.ip_address()
  def bind_address(host) when host in ["127.0.0.1", "localhost"], do: {127, 0, 0, 1}
  def bind_address("::1"), do: {0, 0, 0, 0, 0, 0, 0, 1}

  def bind_address(other),
    do: raise(ArgumentError, "refusing to bind #{inspect(other)}: loopback only")

  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        pid = spawn(fn -> serve(socket) end)
        :gen_tcp.controlling_process(socket, pid)
        accept_loop(listen_socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("web accept failed: #{inspect(reason)}")
        accept_loop(listen_socket)
    end
  end

  defp serve(socket) do
    case read_request(socket) do
      {:ok, request} ->
        handle(socket, request)

      {:error, reason} ->
        respond(socket, 400, "text/plain", "bad request: #{inspect(reason)}")
        :gen_tcp.close(socket)
    end
  catch
    kind, reason ->
      Logger.error("web handler crashed: #{inspect(kind)} #{inspect(reason)}")
      respond(socket, 500, "application/json", ~s({"error":"internal error"}))
      :gen_tcp.close(socket)
  end

  defp handle(socket, %{method: method, path: path, query: query, body: body}) do
    case Router.route(method, path, query, body) do
      # The SSE branch owns the socket from here: it writes its own status line
      # and then blocks writing frames until the peer goes away.
      {:stream, initial} ->
        ShemSpolia.Web.Stream.run(socket, initial)

      {status, content_type, payload} ->
        respond(socket, status, content_type, payload)
        :gen_tcp.close(socket)
    end
  end

  # ── request parsing ──────────────────────────────────────────────────────

  defp read_request(socket) do
    deadline = System.monotonic_time(:millisecond) + @read_timeout

    with {:ok, head, rest} <- read_until_headers(socket, "", deadline),
         {:ok, method, target, headers} <- parse_head(head),
         {:ok, body} <- read_body(socket, headers, rest, deadline) do
      {path, query} = split_target(target)
      {:ok, %{method: method, path: path, query: query, headers: headers, body: body}}
    end
  end

  defp read_until_headers(socket, acc, deadline) do
    cond do
      byte_size(acc) > @max_request_bytes ->
        {:error, :headers_too_large}

      true ->
        case :binary.match(acc, "\r\n\r\n") do
          {pos, 4} ->
            <<head::binary-size(pos), _::binary-size(4), rest::binary>> = acc
            {:ok, head, rest}

          :nomatch ->
            with {:ok, chunk} <- recv(socket, deadline) do
              read_until_headers(socket, acc <> chunk, deadline)
            end
        end
    end
  end

  defp parse_head(head) do
    [request_line | header_lines] = String.split(head, "\r\n")

    case String.split(request_line, " ", parts: 3) do
      [method, target, _version] ->
        headers =
          for line <- header_lines,
              [k, v] <- [String.split(line, ":", parts: 2)],
              into: %{} do
            {k |> String.trim() |> String.downcase(), String.trim(v)}
          end

        {:ok, method, target, headers}

      _ ->
        {:error, {:bad_request_line, request_line}}
    end
  end

  defp read_body(socket, headers, rest, deadline) do
    case headers["content-length"] do
      nil ->
        {:ok, rest}

      raw ->
        case Integer.parse(raw) do
          {len, _} when len >= 0 and len <= @max_request_bytes ->
            read_length(socket, rest, len, deadline)

          {len, _} ->
            {:error, {:body_too_large, len}}

          :error ->
            {:error, {:bad_content_length, raw}}
        end
    end
  end

  defp read_length(_socket, acc, len, _deadline) when byte_size(acc) >= len,
    do: {:ok, binary_part(acc, 0, len)}

  defp read_length(socket, acc, len, deadline) do
    with {:ok, chunk} <- recv(socket, deadline) do
      read_length(socket, acc <> chunk, len, deadline)
    end
  end

  defp split_target(target) do
    case String.split(target, "?", parts: 2) do
      [path] -> {path, %{}}
      [path, qs] -> {path, decode_query(qs)}
    end
  end

  @doc false
  def decode_query(""), do: %{}

  def decode_query(qs) do
    for pair <- String.split(qs, "&"), pair != "", into: %{} do
      case String.split(pair, "=", parts: 2) do
        [k, v] -> {URI.decode_www_form(k), URI.decode_www_form(v)}
        [k] -> {URI.decode_www_form(k), ""}
      end
    end
  end

  defp recv(socket, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      :gen_tcp.recv(socket, 0, remaining)
    end
  end

  # ── response ─────────────────────────────────────────────────────────────

  @spec respond(:gen_tcp.socket(), pos_integer(), String.t(), iodata()) :: :ok | {:error, term()}
  def respond(socket, status, content_type, payload) do
    body = IO.iodata_to_binary(payload)

    :gen_tcp.send(socket, [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " ",
      reason(status),
      "\r\n",
      "Content-Type: ",
      content_type,
      "\r\n",
      "Content-Length: ",
      Integer.to_string(byte_size(body)),
      "\r\n",
      # The UI is served from the same origin and the server is loopback-only;
      # no reason for anything else on the machine to script against it.
      "Cache-Control: no-store\r\n",
      Assets.security_headers(),
      "Connection: close\r\n\r\n",
      body
    ])
  end

  defp reason(200), do: "OK"
  defp reason(201), do: "Created"
  defp reason(400), do: "Bad Request"
  defp reason(404), do: "Not Found"
  defp reason(405), do: "Method Not Allowed"
  defp reason(409), do: "Conflict"
  defp reason(422), do: "Unprocessable Entity"
  defp reason(500), do: "Internal Server Error"
  defp reason(_), do: "OK"
end
