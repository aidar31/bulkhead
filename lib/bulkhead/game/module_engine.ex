defmodule Bulkhead.Game.ModuleEngine do
  @doc """
  Принимает базовые stats корабля и список установленных модулей.
  Возвращает финальные stats с учётом всех эффектов.
  """
  def apply_modules(base_stats, modules) do
    Enum.reduce(modules, base_stats, &apply_module_effects/2)
  end

  defp apply_module_effects(module_def, stats) do
    Enum.reduce(module_def.effects, stats, fn {stat_key, operation}, acc ->
      apply_op(acc, stat_key, operation["op"], operation["value"])
    end)
  end

  defp apply_op(stats, key, "add", value) do
    Map.update(stats, key, value, &(&1 + value))
  end

  defp apply_op(stats, key, "mul", value) do
    Map.update(stats, key, value, &Float.round(&1 * value, 2))
  end

  defp apply_op(stats, key, "set", value) do
    Map.put(stats, key, value)
  end
end
