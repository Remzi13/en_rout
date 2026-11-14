# 005. Периодическое предупреждение Jolt «job system exceeded the maximum number of jobs»

- **Серьёзность:** cosmetic (на геймплей не влияет, повторяется не всегда)
- **Статус:** открыт, наблюдение.

## Шаги воспроизведения
Headless-запуск, например `godot --headless --fixed-fps 60 --path . --quit-after 600` (главная сцена) или любой тест из `tests/headless/`.

## Ожидалось
Лог без предупреждений.

## Получилось
```
WARNING: Jolt Physics job system exceeded the maximum number of jobs. This should not happen. Please report this. Waiting for jobs to become available...
     at: CreateJob (modules/jolt_physics/spaces/jolt_job_system.cpp:123)
```
Один раз за запуск, примерно в каждом четвёртом запуске (4 из 17 логов в `tests/.logs/` после прогона `run_all.sh`, на главной сцене повторилось 1 раз из 4). Падений и ошибок физики вместе с ним не замечено. Причина не выяснена; вероятно, связано с числом потоков headless-окружения (10 ядер), а не с игровым кодом.

## Предложение
Проверить на Windows/целевом железе и в редакторе. Если повторится, завести issue в godot (Jolt) и/или ограничить `physics/jolt_physics_3d/simulation/...` потоки. Игровой код менять, скорее всего, не нужно.
