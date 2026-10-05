defmodule ExMaude.Verification.Budget do
  @moduledoc """
  Passive deadline arithmetic with an explicit monotonic clock observation.

  The absolute timestamp belongs to one caller VM. No clock is read here and
  no worker, global configuration or telemetry is created. `:none` preserves
  an omitted deadline's per-operation cap.
  """
  @doc """
  Narrows a positive operation cap to the remaining absolute budget.

  Exact or past expiry returns `{:error, :expired}`; malformed arguments return
  `{:error, :invalid}`. Signed integer timestamps are valid clock observations.
  """
  @spec remaining(pos_integer(), integer() | :none, integer()) ::
          {:ok, pos_integer()} | {:error, :expired | :invalid}
  def remaining(timeout, :none, now) when is_integer(timeout) and timeout > 0 and is_integer(now),
    do: {:ok, timeout}

  def remaining(timeout, deadline, now)
      when is_integer(timeout) and timeout > 0 and is_integer(deadline) and is_integer(now) do
    if deadline > now, do: {:ok, min(timeout, deadline - now)}, else: {:error, :expired}
  end

  def remaining(_, _, _), do: {:error, :invalid}
end
