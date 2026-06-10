defmodule ExMaude.Backend.NIFTest do
  @moduledoc false

  # Mutates global config (Application.put_env) — must not run concurrently
  # with other suites that read it.
  use ExUnit.Case, async: false

  alias ExMaude.Backend
  alias ExMaude.Backend.NIF

  describe "module structure" do
    setup do
      Code.ensure_loaded!(NIF)
      :ok
    end

    test "implements Backend behaviour" do
      behaviours = NIF.__info__(:attributes)[:behaviour] || []
      assert ExMaude.Backend in behaviours
    end

    test "is a GenServer" do
      assert function_exported?(NIF, :init, 1)
      assert function_exported?(NIF, :handle_call, 3)
      assert function_exported?(NIF, :handle_info, 2)
      assert function_exported?(NIF, :terminate, 2)
    end

    test "exports all Backend callbacks" do
      assert function_exported?(NIF, :start_link, 1)
      assert function_exported?(NIF, :execute, 3)
      assert function_exported?(NIF, :alive?, 1)
      assert function_exported?(NIF, :load_file, 2)
      assert function_exported?(NIF, :stop, 1)
    end
  end

  describe "availability" do
    @tag :nif
    test "available? returns true when the NIF is loaded" do
      assert Backend.available?(:nif)
    end
  end

  describe "configuration" do
    test "impl returns NIF when configured" do
      original = Application.get_env(:ex_maude, :backend)

      try do
        Application.put_env(:ex_maude, :backend, :nif)
        assert Backend.impl() == ExMaude.Backend.NIF
      after
        if original do
          Application.put_env(:ex_maude, :backend, original)
        else
          Application.delete_env(:ex_maude, :backend)
        end
      end
    end
  end
end
