defmodule Bulkhead.Game.RoleEngine do
  @doc """
  Мёржит все эффекты от всех ролей игрока в один map.
  Числа суммируются, булевы — OR.

  iex> merge_effects([%{"mission_reward_bonus" => 0.2}, %{"mission_reward_bonus" => 0.1}])
  %{"mission_reward_bonus" => 0.3}
  """
  def merge_effects(effects_list) do
    Enum.reduce(effects_list, %{}, fn effects, acc ->
      Map.merge(acc, effects, fn _key, v1, v2 ->
        cond do
          is_number(v1) and is_number(v2) -> v1 + v2
          is_boolean(v1) or is_boolean(v2) -> v1 || v2
          true -> v2
        end
      end)
    end)
  end

  @doc "Проверяет permission (can_* эффекты)"
  def can?(merged_effects, permission) do
    Map.get(merged_effects, to_string(permission), false) == true
  end

  @doc "Возвращает числовой бонус (0.0 если нет)"
  def bonus(merged_effects, effect_name) do
    Map.get(merged_effects, to_string(effect_name), 0.0)
  end

  @doc "Применяет бонус к числу: value * (1 + bonus)"
  def apply_bonus(value, merged_effects, effect_name) do
    trunc(value * (1.0 + bonus(merged_effects, effect_name)))
  end

  @doc "Проверяет constraint max_per_guild"
  def within_limit?(role_def, current_count) do
    case get_in(role_def.constraints, ["max_per_guild"]) do
      nil -> true
      max -> current_count < max
    end
  end
end
