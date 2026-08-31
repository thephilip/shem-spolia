defmodule ShemSpolia.MCP.Tools.ExportBundle do
  use ShemSpolia.MCP.Tool

  @impl true
  def name, do: "audit.export_bundle"

  @impl true
  def description,
    do:
      "Export a recorded session as a portable attest bundle (events.jsonl, manifest.json, " <>
        "tools/, verify.py). Returns the bundle path; verify it anywhere with `python3 verify.py <dir>`."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "session_id" => %{"type" => "string", "description" => "Session to export."},
        "out_dir" => %{
          "type" => "string",
          "description" => "Directory to write the bundle into. Defaults to the working directory."
        }
      },
      "required" => ["session_id"]
    }
  end

  @impl true
  def call(%{"session_id" => session_id} = args) do
    out = Map.get(args, "out_dir") || File.cwd!()

    case ShemSpolia.Attest.build(session_id, out: out) do
      {:ok, dir} ->
        {:ok,
         %{
           bundle_path: dir,
           verify_command: "python3 #{Path.join(dir, "verify.py")} #{dir}"
         }}

      {:error, {:chain_broken, {:broken_at, id}}} ->
        {:error, "refusing to export #{session_id}: chain broken at #{id}"}

      {:error, :not_found} ->
        {:error, "session not found: #{session_id}"}

      {:error, reason} ->
        {:error, "export failed: #{inspect(reason)}"}
    end
  end

  def call(_), do: {:error, "session_id is required"}
end