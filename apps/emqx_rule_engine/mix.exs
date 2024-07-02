defmodule EMQXRuleEngine.MixProject do
  use Mix.Project
  alias EMQXUmbrella.MixProject, as: UMP

  def project do
    [
      app: :emqx_rule_engine,
      version: "0.1.0",
      build_path: "../../_build",
      erlc_options: UMP.erlc_options(),
      erlc_paths: UMP.erlc_paths(),
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: UMP.extra_applications(), mod: {:emqx_rule_engine_app, []}]
  end

  def deps() do
    [
      {:emqx, in_umbrella: true},
      {:emqx_ctl, in_umbrella: true},
      {:emqx_utils, in_umbrella: true},
      {:emqx_modules, in_umbrella: true},
      {:emqx_resource, in_umbrella: true},
      {:emqx_bridge, in_umbrella: true},
      {:emqtt,
       github: "emqx/emqtt", tag: "1.10.1", override: true, system_env: maybe_no_quic_env()}
    ]
  end

  defp maybe_no_quic_env() do
    UMP.maybe_no_quic_env()
  end
end