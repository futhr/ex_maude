defmodule ExMaude.Config do
  @moduledoc """
  Runtime configuration readers shared by ExMaude components.

  Values are read when an operation starts, so changing application
  configuration affects new commands without recompiling the project.
  """

  @doc """
  Returns the configured default timeout when it is a positive integer.

  Invalid or missing configuration falls back to the positive value supplied
  by the caller.
  """
  @spec timeout(pos_integer()) :: pos_integer()
  def timeout(fallback) when is_integer(fallback) and fallback > 0 do
    case Application.get_env(:ex_maude, :timeout, fallback) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> fallback
    end
  end
end
