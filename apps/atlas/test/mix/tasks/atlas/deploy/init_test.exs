defmodule Mix.Tasks.Atlas.Deploy.InitTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Atlas.Deploy.Init

  describe "build_script_args/3" do
    test "omits --file when no sudoers override is given" do
      assert Init.build_script_args("builder", "/abs/exec-port", nil) ==
               ["--user", "builder", "--binary", "/abs/exec-port"]
    end

    test "appends --file <path> when a sudoers override is supplied" do
      assert Init.build_script_args(
               "builder",
               "/abs/exec-port",
               "/tmp/erlexec.sudoers"
             ) == [
               "--user",
               "builder",
               "--binary",
               "/abs/exec-port",
               "--file",
               "/tmp/erlexec.sudoers"
             ]
    end
  end

  describe "list_exec_ports/1" do
    test "returns [] when the priv directory does not exist" do
      assert Init.list_exec_ports("/no/such/path/at/all") == []
    end

    test "returns [] when no arch subdirectory contains exec-port" do
      tmp = make_tmp_priv()
      File.mkdir_p!(Path.join(tmp, "x86_64-pc-linux-gnu"))

      assert Init.list_exec_ports(tmp) == []
    end

    test "returns the matching binary when exactly one arch directory has it" do
      tmp = make_tmp_priv()
      arch_dir = Path.join(tmp, "x86_64-pc-linux-gnu")
      port = Path.join(arch_dir, "exec-port")
      File.mkdir_p!(arch_dir)
      File.write!(port, "fake binary")

      assert Init.list_exec_ports(tmp) == [Path.expand(port)]
    end

    test "returns both paths when two arch directories each contain exec-port" do
      tmp = make_tmp_priv()
      a = Path.join([tmp, "arch-a", "exec-port"])
      b = Path.join([tmp, "arch-b", "exec-port"])
      File.mkdir_p!(Path.dirname(a))
      File.mkdir_p!(Path.dirname(b))
      File.write!(a, "")
      File.write!(b, "")

      result = Init.list_exec_ports(tmp) |> Enum.sort()
      assert result == Enum.sort([Path.expand(a), Path.expand(b)])
    end
  end

  describe "find_exec_port!/1" do
    test "returns the binary when exactly one match exists" do
      tmp = make_tmp_priv()
      arch_dir = Path.join(tmp, "x86_64-pc-linux-gnu")
      port = Path.join(arch_dir, "exec-port")
      File.mkdir_p!(arch_dir)
      File.write!(port, "fake binary")

      assert Init.find_exec_port!(tmp) == Path.expand(port)
    end

    test "raises a helpful Mix.Error when no binary is found" do
      tmp = make_tmp_priv()

      assert_raise Mix.Error,
                   ~r/could not find exec-port.*deps\.compile erlexec/s,
                   fn -> Init.find_exec_port!(tmp) end
    end

    test "raises a Mix.Error listing the paths when more than one match exists" do
      tmp = make_tmp_priv()
      File.mkdir_p!(Path.join([tmp, "arch-a"]))
      File.mkdir_p!(Path.join([tmp, "arch-b"]))
      File.write!(Path.join([tmp, "arch-a", "exec-port"]), "")
      File.write!(Path.join([tmp, "arch-b", "exec-port"]), "")

      assert_raise Mix.Error, ~r/found multiple exec-port/, fn ->
        Init.find_exec_port!(tmp)
      end
    end
  end

  describe "default_script_path/0" do
    test "ends with priv/scripts/setup-erlexec-sudoers.sh" do
      assert String.ends_with?(
               Init.default_script_path(),
               Path.join(["priv", "scripts", "setup-erlexec-sudoers.sh"])
             )
    end

    test "resolves under :atlas's app dir" do
      assert String.starts_with?(
               Init.default_script_path(),
               Application.app_dir(:atlas)
             )
    end
  end

  describe "run/1 input validation" do
    test "raises when --user is not provided" do
      assert_raise Mix.Error, ~r/--user is required/, fn ->
        Init.run([])
      end
    end
  end

  # --------------------------------------------------------------------

  defp make_tmp_priv do
    dir =
      Path.join([
        System.tmp_dir!(),
        "atlas-deploy-init-test-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    on_exit_cleanup(dir)
    dir
  end

  defp on_exit_cleanup(dir) do
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
  end
end
