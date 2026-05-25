defmodule Mix.Tasks.Atlas.Tunnels.StartTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Atlas.Tunnels.Start

  describe "parse_backend_override!/1" do
    test "maps \"named\" to :named" do
      assert Start.parse_backend_override!("named") == :named
    end

    test "maps \"quick\" to :quick" do
      assert Start.parse_backend_override!("quick") == :quick
    end

    test "maps \"none\" to :none" do
      assert Start.parse_backend_override!("none") == :none
    end

    test "parses a CamelCase module name into the matching atom" do
      assert Start.parse_backend_override!("Atlas.Tunnel.Stub") ==
               Atlas.Tunnel.Stub
    end

    test "parses a deeply nested module name" do
      assert Start.parse_backend_override!("Foo.Bar.Baz.Qux") ==
               :"Elixir.Foo.Bar.Baz.Qux"
    end

    test "raises Mix.Error on an unknown lower-case value" do
      assert_raise Mix.Error, ~r/invalid --backend value/, fn ->
        Start.parse_backend_override!("nope")
      end
    end

    test "raises Mix.Error on a value with leading whitespace" do
      assert_raise Mix.Error, ~r/invalid --backend value/, fn ->
        Start.parse_backend_override!(" named")
      end
    end

    test "raises Mix.Error on a value with embedded shell characters" do
      assert_raise Mix.Error, ~r/invalid --backend value/, fn ->
        Start.parse_backend_override!("foo;rm -rf")
      end
    end
  end
end
