defmodule FlameAppleContainerBackendTest do
  use ExUnit.Case
  doctest FlameAppleContainerBackend

  test "greets the world" do
    assert FlameAppleContainerBackend.hello() == :world
  end
end
