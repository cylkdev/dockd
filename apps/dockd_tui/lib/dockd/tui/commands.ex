defmodule Dockd.Tui.Commands do
  @moduledoc """
  Static catalog of the commands surfaced in the dashboard's command panel and
  the per-instance action bar. Pure data — the dashboard reads this to render
  the lists and to decide whether a command opens a form or runs immediately.
  """

  @type field :: %{key: atom(), label: binary(), required: boolean()}
  @type command :: %{key: atom(), label: binary(), fields: [field()]}

  @spec all() :: [command()]
  def all do
    [
      %{
        key: :instance_run,
        label: "instance run",
        fields: [
          %{key: :image, label: "Image", required: true},
          %{key: :name, label: "Name", required: false},
          %{key: :tag, label: "Tag", required: false}
        ]
      },
      %{
        key: :package_install,
        label: "package install",
        fields: [
          %{key: :source, label: "Git source URL", required: true}
        ]
      },
      %{key: :package_show, label: "package show", fields: []},
      %{key: :info, label: "info", fields: []},
      %{
        key: :ssh_generate,
        label: "ssh generate script",
        fields: [
          %{key: :output_dir, label: "Output dir (blank = cwd)", required: false}
        ]
      },
      %{
        key: :ssh_install,
        label: "ssh install script",
        fields: [
          %{key: :user_at_host, label: "user@host", required: true},
          %{key: :remote_path, label: "Remote path", required: false}
        ]
      }
    ]
  end

  @type instance_action :: %{key: char(), action: atom(), label: binary()}

  @spec instance_actions() :: [instance_action()]
  def instance_actions do
    [
      %{key: ?s, action: :shell, label: "[s]hell"},
      %{key: ?l, action: :logs, label: "[l]ogs"},
      %{key: ?x, action: :stop, label: "[x]stop"},
      %{key: ?S, action: :start, label: "[S]tart"},
      %{key: ?r, action: :restart, label: "[r]estart"},
      %{key: ?d, action: :destroy, label: "[d]estroy"},
      %{key: ?i, action: :inspect, label: "[i]nspect"}
    ]
  end
end
