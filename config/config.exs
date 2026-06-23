import Config

config :dockd,
  temp_dir: "/tmp/dockd"

config :dockd_rpc,
  service_name: "my_service",
  node_filter: "my_service",
  cluster_topology: [],
  rpc: true
