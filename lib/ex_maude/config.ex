defmodule ExMaude.Config do
  @moduledoc false

  @spec timeout(pos_integer()) :: pos_integer()
  def timeout(fallback) when is_integer(fallback) and fallback > 0 do
    case Application.get_env(:ex_maude, :timeout, fallback) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> fallback
    end
  end
end
