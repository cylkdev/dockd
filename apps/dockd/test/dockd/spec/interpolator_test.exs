defmodule Dockd.Spec.InterpolatorTest do
  use ExUnit.Case, async: true

  alias Dockd.Spec.Interpolator

  describe "substitute/2" do
    test "substitutes a ${VAR} reference from the env map" do
      assert {:ok, "hello world"} = Interpolator.substitute("hello ${WHO}", %{"WHO" => "world"})
    end

    test "uses the default form when ${VAR:-default} has no env hit" do
      assert {:ok, "fallback"} = Interpolator.substitute("${MISSING:-fallback}", %{})
    end

    test "prefers the env value over the default when both are available" do
      assert {:ok, "real"} =
               Interpolator.substitute("${VAR:-default}", %{"VAR" => "real"})
    end

    test "errors when a reference is missing and has no default" do
      assert {:error, error} = Interpolator.substitute("${MISSING}", %{})
      assert error.phase === :validate
      assert error.message =~ "unset env var: MISSING"
    end

    test "recurses into lists" do
      assert {:ok, ["a-x", "b-y"]} =
               Interpolator.substitute(["a-${A}", "b-${B}"], %{"A" => "x", "B" => "y"})
    end

    test "recurses into maps" do
      assert {:ok, %{"k" => "v-x"}} =
               Interpolator.substitute(%{"k" => "v-${A}"}, %{"A" => "x"})
    end

    test "leaves non-strings untouched" do
      assert {:ok, 42} = Interpolator.substitute(42, %{})
      assert {:ok, true} = Interpolator.substitute(true, %{})
      assert {:ok, nil} = Interpolator.substitute(nil, %{})
    end

    test "reports a useful path for nested misses" do
      assert {:error, error} =
               Interpolator.substitute(%{"a" => ["x", "${MISSING}"]}, %{})

      assert error.message =~ "$.a[1]"
    end
  end
end
