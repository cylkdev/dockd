import Config

config :dockd,
  temp_dir: "/tmp/dockd"

config :shared_rpc,
  rpc_enabled: true

# The `dockd` CLI treats stdout as data: JSON output (`--json`) and the
# `docker exec` line printed by `instance shell --print`. Keep Logger off stdout
# so a stray log line can never corrupt that output.
config :logger, default_handler: [config: [type: :standard_error]]
