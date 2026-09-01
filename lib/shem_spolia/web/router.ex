defmodule ShemSpolia.Web.Router do
  @moduledoc """
  Path dispatch. Returns `{status, content_type, body}` or `{:stream, initial}`.

  Routing is a `case` over split path segments rather than a macro DSL — there
  are eleven routes and no plug pipeline to configure, so a DSL would be more
  machinery than the thing it routes.
  """

  alias ShemSpolia.Web.{API, Assets}

  @json "application/json"

  @spec route(String.t(), String.t(), map(), binary()) ::
          {pos_integer(), String.t(), iodata()} | {:stream, map()}
  def route(method, path, query, body) do
    segments = path |> String.split("/", trim: true) |> Enum.map(&URI.decode/1)

    dispatch(method, segments, query, body)
  end

  # ── UI ───────────────────────────────────────────────────────────────────

  defp dispatch("GET", [], _q, _b), do: Assets.serve("index.html")
  defp dispatch("GET", ["app.js"], _q, _b), do: Assets.serve("app.js")
  defp dispatch("GET", ["app.css"], _q, _b), do: Assets.serve("app.css")
  defp dispatch("GET", ["vendor", "preact.js"], _q, _b), do: Assets.serve("preact.js")

  # Fonts are matched by name against the embedded set rather than by pattern:
  # the CSS references them with a relative path, and an attacker-supplied
  # segment can never resolve to anything that was not compiled in.
  defp dispatch("GET", ["fonts", file], _q, _b) do
    name = "fonts/" <> file
    if Assets.known?(name), do: Assets.serve(name), else: {404, "text/plain", "no such asset"}
  end

  defp dispatch("GET", ["favicon.ico"], _q, _b), do: {404, "text/plain", ""}

  # ── API ──────────────────────────────────────────────────────────────────

  defp dispatch("GET", ["api", "stats"], _q, _b), do: json(API.stats())
  defp dispatch("GET", ["api", "sessions"], _q, _b), do: json(API.sessions())
  defp dispatch("GET", ["api", "recall"], q, _b), do: json(API.recall(q))

  defp dispatch("GET", ["api", "sessions", id, "events"], _q, _b), do: json(API.events(id))
  defp dispatch("GET", ["api", "sessions", id, "verify"], _q, _b), do: json(API.verify(id))

  defp dispatch("POST", ["api", "sessions", id, "attest"], _q, body),
    do: with_params(body, &json(API.attest(id, &1)))

  defp dispatch("POST", ["api", "sessions", id, "fork"], _q, body),
    do: with_params(body, &json(API.fork(id, &1)))

  # Live tail. Held open by Web.Stream, not answered here.
  defp dispatch("GET", ["api", "stream"], q, _b), do: {:stream, q}

  # ── fallbacks ────────────────────────────────────────────────────────────

  # A known path reached with the wrong verb is a 405, not a 404: the
  # difference tells a client whether to fix its URL or its method.
  defp dispatch(_method, ["api" | _] = segments, _q, _b) do
    if known_path?(segments) do
      {405, @json, Jason.encode!(%{error: "method not allowed"})}
    else
      {404, @json,
       Jason.encode!(%{error: "no such endpoint", path: "/" <> Enum.join(segments, "/")})}
    end
  end

  defp dispatch(_method, _segments, _q, _b),
    do: {404, "text/plain", "not found"}

  defp known_path?(["api", "stats"]), do: true
  defp known_path?(["api", "sessions"]), do: true
  defp known_path?(["api", "recall"]), do: true
  defp known_path?(["api", "stream"]), do: true

  defp known_path?(["api", "sessions", _, action]) when action in ~w(events verify attest fork),
    do: true

  defp known_path?(_), do: false

  # ── helpers ──────────────────────────────────────────────────────────────

  defp with_params("", fun), do: fun.(%{})

  defp with_params(body, fun) do
    case Jason.decode(body) do
      {:ok, params} when is_map(params) -> fun.(params)
      {:ok, _} -> {422, @json, Jason.encode!(%{error: "body must be a JSON object"})}
      {:error, _} -> {400, @json, Jason.encode!(%{error: "invalid JSON body"})}
    end
  end

  defp json({status, payload}), do: {status, @json, Jason.encode!(payload)}
end
