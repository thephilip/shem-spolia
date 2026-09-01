defmodule ShemSpolia.MixProject do
  use Mix.Project

  def project do
    [
      app: :shem_spolia,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
      description: "Portable, offline-verifiable auditor for local-model agents",
      source_url: "https://github.com/thephilip/shem-spolia",
      package: package()
    ]
  end

  def application do
    [
      # :mnesia and :dets(:stdlib) ship with OTP — listed here, never in deps/0.
      extra_applications: [:logger, :crypto, :mnesia],
      mod: {ShemSpolia.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end

  # `mix escript.build` -> ./shem_audit (needs only `escript` + an Erlang runtime)
  defp escript do
    [
      main_module: ShemSpolia.CLI,
      name: :shem_audit,
      app: nil
    ]
  end

  defp package do
    [
      name: :shem_spolia,
      files: ~w(lib priv mix.exs README.md LICENSE),
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/thephilip/shem-spolia"}
    ]
  end
end