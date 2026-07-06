defmodule DockdCLI.Commands.InfoPackageTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias DockdCLI.Commands.Info
  alias DockdCLI.Commands.Package.{Install, Show, Validate}

  test "info renders sections under headers" do
    info = %{temp_files: %{count: 2, total_bytes: 10, oldest_at: nil, newest_at: nil}}
    out = capture_io(fn -> assert Info.render({:ok, info}) == :ok end)
    assert out =~ "[temp_files]" and out =~ "count: 2" and out =~ "oldest_at: -"
  end

  test "info returns an error message for a Dockd.Error" do
    err = %Dockd.Error{phase: :discover, message: "boom"}
    assert Info.render({:error, err}) == {:error, Exception.message(err)}
  end

  test "info render_json emits the info map as JSON" do
    info = %{temp_files: %{count: 2, total_bytes: 10, oldest_at: nil, newest_at: nil}}
    out = capture_io(fn -> assert Info.render_json({:ok, info}) == :ok end)

    assert Jason.decode!(out) == %{
             "temp_files" => %{
               "count" => 2,
               "total_bytes" => 10,
               "oldest_at" => nil,
               "newest_at" => nil
             }
           }
  end

  test "info render_json returns the Dockd.Error struct unchanged" do
    err = %Dockd.Error{phase: :discover, message: "boom"}
    assert Info.render_json({:error, err}) == {:error, err}
  end

  test "package install requires a source type positional and a --source flag" do
    assert {:error, msg} = Install.run(%{}, [])
    assert msg =~ "Missing required source argument"

    assert {:error, msg} = Install.run(%{type: "git"}, [])
    assert msg =~ "Missing required --source"
  end

  test "package install rejects unsupported source types" do
    assert {:error, msg} = Install.run(%{type: "svn", source: "http://example.com"}, [])
    assert msg =~ "Unsupported source"
  end

  test "package show takes no required arguments and reports an empty package list" do
    out =
      capture_io(fn ->
        assert Show.run(%{}, packages_path: empty_dir()) == :ok
      end)

    assert out =~ "No installed packages."
  end

  test "package validate takes no required arguments and reports an empty package list" do
    out =
      capture_io(fn ->
        assert Validate.run(%{}, packages_path: empty_dir()) == :ok
      end)

    assert out =~ "No installed packages."
  end

  test "package show run_json emits an empty array when no packages" do
    out = capture_io(fn -> assert Show.run_json(%{}, packages_path: empty_dir()) == :ok end)
    assert Jason.decode!(out) == []
  end

  test "package validate run_json emits an empty array when no packages" do
    out = capture_io(fn -> assert Validate.run_json(%{}, packages_path: empty_dir()) == :ok end)
    assert Jason.decode!(out) == []
  end

  defp empty_dir do
    path = Path.join(System.tmp_dir!(), "dockd-cli-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
