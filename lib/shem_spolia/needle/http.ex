defmodule ShemSpolia.Needle.HTTP do
  @moduledoc """
  A minimal HTTP/1.1 POST client over `:gen_tcp`, for talking to a local
  `needle --serve` process.

  Deliberately not `:httpc`: that pulls in `:ssl` and `:public_key` at request
  time (it builds TLS defaults before it looks at the scheme), which fails in a
  stripped escript and would mean bundling a TLS stack to POST to 127.0.0.1.
  This is a loopback request with a known-shaped response, so the honest
  implementation is the small one.

  Handles `Content-Length` and `Transfer-Encoding: chunked` responses. Not a
  general-purpose client: no redirects, no keep-alive, no TLS.
  """

  @spec post(:inet.port_number(), String.t(), binary(), timeout()) ::
          {:ok, binary()} | {:error, term()}
  def post(port, path, body, timeout \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    request = [
      "POST ", path, " HTTP/1.1\r\n",
      "Host: 127.0.0.1:", Integer.to_string(port), "\r\n",
      "Content-Type: application/json\r\n",
      "Content-Length: ", Integer.to_string(byte_size(body)), "\r\n",
      "Connection: close\r\n\r\n",
      body
    ]

    with {:ok, socket} <-
           :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], timeout),
         :ok <- :gen_tcp.send(socket, request),
         {:ok, response} <- read_response(socket, deadline) do
      :gen_tcp.close(socket)
      response
    else
      {:error, reason} -> {:error, {:http_error, reason}}
    end
  end

  defp read_response(socket, deadline) do
    with {:ok, head, rest} <- read_until_headers(socket, "", deadline),
         {:ok, status, headers} <- parse_head(head) do
      case body(socket, headers, rest, deadline) do
        {:ok, body} when status in 200..299 -> {:ok, {:ok, body}}
        {:ok, body} -> {:ok, {:error, {:http_status, status, body}}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp read_until_headers(socket, acc, deadline) do
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

  defp parse_head(head) do
    [status_line | header_lines] = String.split(head, "\r\n")

    case String.split(status_line, " ", parts: 3) do
      [_version, code, _reason] ->
        headers =
          for line <- header_lines,
              [k, v] <- [String.split(line, ":", parts: 2)],
              into: %{} do
            {k |> String.trim() |> String.downcase(), String.trim(v)}
          end

        {:ok, String.to_integer(code), headers}

      _ ->
        {:error, {:bad_status_line, status_line}}
    end
  end

  defp body(socket, headers, rest, deadline) do
    cond do
      headers["transfer-encoding"] == "chunked" ->
        read_chunked(socket, rest, "", deadline)

      length = headers["content-length"] ->
        read_length(socket, rest, String.to_integer(length), deadline)

      true ->
        read_until_close(socket, rest, deadline)
    end
  end

  defp read_length(_socket, acc, len, _deadline) when byte_size(acc) >= len,
    do: {:ok, binary_part(acc, 0, len)}

  defp read_length(socket, acc, len, deadline) do
    with {:ok, chunk} <- recv(socket, deadline) do
      read_length(socket, acc <> chunk, len, deadline)
    end
  end

  defp read_until_close(socket, acc, deadline) do
    case recv(socket, deadline) do
      {:ok, chunk} -> read_until_close(socket, acc <> chunk, deadline)
      {:error, :closed} -> {:ok, acc}
      error -> error
    end
  end

  defp read_chunked(socket, buffer, acc, deadline) do
    case :binary.match(buffer, "\r\n") do
      :nomatch ->
        with {:ok, chunk} <- recv(socket, deadline) do
          read_chunked(socket, buffer <> chunk, acc, deadline)
        end

      {pos, 2} ->
        <<size_line::binary-size(pos), _::binary-size(2), rest::binary>> = buffer
        size = size_line |> String.split(";") |> hd() |> String.trim() |> parse_hex()

        cond do
          size == 0 ->
            {:ok, acc}

          byte_size(rest) >= size + 2 ->
            <<chunk::binary-size(size), _crlf::binary-size(2), remainder::binary>> = rest
            read_chunked(socket, remainder, acc <> chunk, deadline)

          true ->
            with {:ok, more} <- recv(socket, deadline) do
              read_chunked(socket, buffer <> more, acc, deadline)
            end
        end
    end
  end

  defp parse_hex(hex) do
    case Integer.parse(hex, 16) do
      {n, _} -> n
      :error -> 0
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
end