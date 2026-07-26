import Config

# Dockd is a library: callers own stdout. Keep Logger on stderr so a stray log
# line can never corrupt data a caller is writing or reading there.
config :logger, default_handler: [config: [type: :standard_error]]
