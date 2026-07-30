defmodule Dockd.InstanceTest do
  use ExUnit.Case, async: true

  alias Dockd.Instance
  alias Dockd.Spec

  describe "from_inspect/1" do
    test "maps Id, Name (with leading slash), Config, HostConfig, State into an Instance" do
      payload = %{
        "Id" => "abc123",
        "Name" => "/dockd-smoke",
        "Config" => %{
          "Image" => "busybox:1.37.0",
          "Cmd" => ["/bin/sh"],
          "Env" => ["FOO=bar", "BAZ=qux"],
          "Labels" => %{
            "org.dockd.instance" => "true",
            "org.dockd.instance.name" => "smoke",
            "custom" => "value"
          }
        },
        "HostConfig" => %{
          "Binds" => ["/host/path:/container/path"],
          "Mounts" => [%{"Type" => "tmpfs", "Target" => "/tmpfs"}]
        },
        "State" => %{"Running" => true}
      }

      instance = Instance.from_inspect(payload)

      assert instance.id === "abc123"
      assert instance.name === "dockd-smoke"
      assert instance.image === "busybox:1.37.0"
      assert instance.shell === "/bin/sh"
      assert instance.env === ["FOO=bar", "BAZ=qux"]
      assert instance.labels["org.dockd.instance"] === "true"
      assert instance.labels["custom"] === "value"
      assert instance.running? === true

      [bind, structured] = instance.mounts
      assert bind === %{type: :bind, source: "/host/path:/container/path"}
      assert structured["Type"] === "tmpfs"
    end

    test "tolerates missing optional sections" do
      payload = %{"Id" => "x", "Name" => "/dockd-x"}
      instance = Instance.from_inspect(payload)

      assert instance.id === "x"
      assert instance.name === "dockd-x"
      assert instance.image === nil
      assert instance.shell === nil
      assert instance.env === []
      assert instance.mounts === []
      assert instance.labels === %{}
      assert instance.running? === false
    end

    test "handles a Name without a leading slash" do
      instance = Instance.from_inspect(%{"Id" => "x", "Name" => "dockd-x"})
      assert instance.name === "dockd-x"
    end
  end

  describe "managed_labels/1" do
    test "produces the discovery marker and short instance name" do
      {:ok, spec} = Spec.new("busybox:latest", "my-box")
      labels = Instance.managed_labels(spec)

      assert labels["org.dockd.instance"] === "true"
      assert labels["org.dockd.instance.name"] === "my-box"
    end
  end

  describe "short_name/1" do
    test "strips the dockd- prefix from an Instance name" do
      instance = %Instance{id: "x", name: "dockd-foo"}
      assert Instance.short_name(instance) === "foo"
    end
  end
end
