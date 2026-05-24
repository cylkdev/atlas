defmodule AtlasProviderTest do
  use ExUnit.Case
  doctest AtlasProvider

  test "greets the world" do
    assert AtlasProvider.hello() == :world
  end
end
