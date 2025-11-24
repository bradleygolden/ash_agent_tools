import Config

config :ash, :validate_domain_resource_inclusion?, false

config :ash_baml,
  clients: [
    test: {AshBaml.Test.BamlClient, baml_src: "../ash_baml/test/support/fixtures/baml_src"}
  ]

config :logger, level: :error
