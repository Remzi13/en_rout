# 008. Утечка ColorRect при каждом показе главного меню

- **Серьёзность:** cosmetic (WARNING при выходе, памяти почти не ест)
- **Статус:** исправлено, ветка fix-menu (лишний `glow` убран из `_backdrop()`; смоук с `--verbose` без утечек). Было и на `main` до задачи 1.

## Шаги
`godot --headless --fixed-fps 60 --path . --quit-after 600 --verbose` (смоук из `tests/run_all.sh`).

## Ожидалось
Выход без утечек.

## Получилось
```
WARNING: 1 RID of type "CanvasItem" was leaked.
WARNING: 2 ObjectDB instances were leaked at exit
Leaked instance: ColorRect:... - Node path:
ERROR: Cannot get path of node as it is not in a scene tree.   (только с --verbose)
```
Каждый показ меню добавляет ещё по одному: в `test_main_menu` (меню показывается 5 раз) — 8 RID и 16–28 объектов (часть может быть не отсюда).

## Причина
В `_backdrop()` создаётся `var glow := ColorRect.new()`, ему ставятся якоря и цвет, но в дерево он не добавляется (градиент рисует `TextureRect`). Узел вне дерева никто не освобождает. Убрать `glow` или освободить его.
