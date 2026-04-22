defmodule PiEx.Extension.LoaderTest do
  use ExUnit.Case, async: true

  alias PiEx.Extension.Loader

  @tag :tmp_dir
  test "discover finds .exs files in directories", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "my_ext.exs"), "# ext")
    File.write!(Path.join(tmp_dir, "other.ex"), "# not an exs")
    File.write!(Path.join(tmp_dir, "another_ext.exs"), "# ext2")

    files = Loader.discover([tmp_dir])
    assert length(files) == 2
    assert Enum.all?(files, &String.ends_with?(&1, ".exs"))
  end

  test "discover returns empty for nonexistent directories" do
    assert Loader.discover(["/tmp/nonexistent_#{:rand.uniform(999_999)}"]) == []
  end

  @tag :tmp_dir
  test "load compiles a valid extension file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "test_ext.exs")

    File.write!(path, """
    defmodule PiEx.Extension.LoaderTest.DynamicExt do
      @behaviour PiEx.Extension

      @impl true
      def init(_config), do: {:ok, %{}}

      @impl true
      def handle_event(_event, _payload, _ctx, state), do: {:ok, state}
    end
    """)

    assert {:ok, mod} = Loader.load(path)
    assert mod == PiEx.Extension.LoaderTest.DynamicExt
    assert {:ok, %{}} = mod.init(%{})
  end

  @tag :tmp_dir
  test "load returns error for file with no extension module", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "no_ext.exs")

    File.write!(path, """
    defmodule PiEx.Extension.LoaderTest.NotAnExtension do
      def hello, do: :world
    end
    """)

    assert {:error, {:no_extension_module, ^path}} = Loader.load(path)
  end

  @tag :tmp_dir
  test "load returns error for invalid syntax", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "bad.exs")
    File.write!(path, "defmodule Foo do end end")

    assert {:error, _} = Loader.load(path)
  end

  @tag :tmp_dir
  test "load_all loads multiple files", %{tmp_dir: tmp_dir} do
    for i <- 1..2 do
      File.write!(Path.join(tmp_dir, "ext_#{i}.exs"), """
      defmodule PiEx.Extension.LoaderTest.Multi#{i} do
        @behaviour PiEx.Extension
        @impl true
        def init(_), do: {:ok, %{}}
        @impl true
        def handle_event(_, _, _, s), do: {:ok, s}
      end
      """)
    end

    results = Loader.load_all(Loader.discover([tmp_dir]))
    assert length(results) == 2
    assert Enum.all?(results, &match?({:ok, _}, &1))
  end
end
