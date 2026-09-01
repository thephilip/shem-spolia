defmodule ShemSpolia.Web.Assets do
  @moduledoc """
  Static files, embedded at COMPILE time.

  Same reason `Attest` embeds `verify.py`: an escript is one archive with no
  unpacked priv directory, so `:code.priv_dir/1` returns `{:error, :bad_name}`
  and any runtime `File.read` of priv/ is a bug that only shows up in the
  shipped binary. `@external_resource` also means editing an asset triggers a
  recompile, so `mix run` and the built binary can never disagree about what
  the UI is.

  The fonts are here for the same reason the CSP has no CDN in it: an auditor
  that claims no network egress cannot fetch a webfont on page load. Courier
  Prime ships under the SIL OFL (see `fonts/OFL.txt`); ~85 KB for three faces
  is a fair price for the UI rendering identically on a machine that has never
  been online.
  """

  @assets_dir Path.join(__DIR__, "../../../priv/web") |> Path.expand()

  @files ~w(
    index.html
    app.js
    app.css
    preact.js
    fonts/CourierPrime-Regular.woff2
    fonts/CourierPrime-Bold.woff2
    fonts/CourierPrime-Italic.woff2
    fonts/OFL.txt
  )

  # Read once at compile time into a name -> {body, etag} map.
  @embedded (for name <- @files, into: %{} do
               path = Path.join(@assets_dir, name)
               body = File.read!(path)

               etag =
                 :crypto.hash(:sha256, body) |> Base.encode16(case: :lower) |> binary_part(0, 16)

               {name, {body, etag}}
             end)

  for name <- @files do
    @external_resource Path.join(@assets_dir, name)
  end

  @spec serve(String.t()) :: {pos_integer(), String.t(), iodata()}
  def serve(name) do
    case @embedded do
      %{^name => {body, _etag}} -> {200, content_type(name), body}
      _ -> {404, "text/plain", "no such asset"}
    end
  end

  @spec etag(String.t()) :: String.t() | nil
  def etag(name) do
    case @embedded do
      %{^name => {_body, etag}} -> etag
      _ -> nil
    end
  end

  @spec known?(String.t()) :: boolean()
  def known?(name), do: Map.has_key?(@embedded, name)

  @doc """
  Headers sent with every response.

  The CSP is the real one, not decoration: `default-src 'self'` with no
  `connect-src` beyond self means that even if a recorded payload rendered into
  the page contained a script or a beacon, it could not reach the network. An
  auditor for offline evidence that could be made to phone home by the content
  it displays would be self-defeating.

  `'unsafe-inline'` is absent — the UI ships as external files precisely so it
  does not need it.
  """
  @spec security_headers() :: iodata()
  def security_headers do
    [
      "Content-Security-Policy: default-src 'self'; img-src 'self' data:; ",
      "style-src 'self'; script-src 'self'; font-src 'self'; connect-src 'self'; ",
      "base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n",
      "X-Content-Type-Options: nosniff\r\n",
      "Referrer-Policy: no-referrer\r\n"
    ]
  end

  defp content_type("index.html"), do: "text/html; charset=utf-8"
  defp content_type("app.css"), do: "text/css; charset=utf-8"

  defp content_type(name) when name in ["app.js", "preact.js"],
    do: "text/javascript; charset=utf-8"

  defp content_type("fonts/OFL.txt"), do: "text/plain; charset=utf-8"

  defp content_type(name) do
    if String.ends_with?(name, ".woff2"),
      do: "font/woff2",
      else: "application/octet-stream"
  end
end
