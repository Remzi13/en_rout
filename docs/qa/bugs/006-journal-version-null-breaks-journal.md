# 006. Журнал с `"version": null` (или массивом) — SCRIPT ERROR, журнал перестаёт работать навсегда

- **Серьёзность:** major (статистика тихо не пишется, файл сам не чинится; задачи 3–5 упадут на `journal == null`)
- **Статус:** открыт. Задача 2, `game/core/journal.gd`.

## Шаги
1. Записать в `user://journal.json` текст `{"version": null}` (или `{"version": [1]}`).
2. `godot --headless --fixed-fps 60 --path . --quit-after 900 -- --autostart --autopilot`
3. Посмотреть лог и `journal.json` после выхода.

Автоматически: `tests/run_all.sh test_journal_broken` (случаи «version: null», «version: массив»).

## Ожидалось
Как для мусора, `{}` и пустого файла: WARNING «повреждён или устарел», новый пустой журнал, при выходе файл перезаписан нормальным.

## Получилось
```
SCRIPT ERROR: Invalid call. Nonexistent 'int' constructor.
   at: load_or_new (res://game/core/journal.gd:59)
```
`Journal.load_or_new` прерывается и возвращает `null`. `OpenWorld.journal == null`, `TripStats` молча ничего не считает и не сохраняет, файл остаётся `{"version": null}`, и так при каждом запуске. Игра не падает только потому, что пока никто, кроме TripStats, журнал не трогает.

## Причина
Строка 59: `int((parsed as Dictionary).get("version", 0))` — `int()` не принимает `null`/`Array`/`Dictionary`. Нужно сначала проверить тип (`v is int or v is float`).
