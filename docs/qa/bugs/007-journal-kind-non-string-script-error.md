# 007. Запись журнала с `kind` не строкой — SCRIPT ERROR в `deliveries_count`

- **Серьёзность:** minor (только руками испорченный файл, но игра сыплет ошибками при каждом `stats()`)
- **Статус:** открыт. Задача 2, `game/core/journal.gd`.

## Шаги
`tests/run_all.sh test_journal_broken`, случай «kind и hour числом/строкой»: файл
`{"version": 1, "entries": [{"kind": 5, "hour": "вечер"}, {"kind": null}]}`.

## Ожидалось
Негодные записи пропускаются при чтении (или сравниваются без ошибки), `stats()` работает тихо.

## Получилось
```
SCRIPT ERROR: Invalid operands 'float' and 'String' in operator '=='.
   at: Journal.deliveries_count (res://game/core/journal.gd:109)
```
`_from_dict` берёт любой словарь в `entries` без проверки полей, а `deliveries_count` сравнивает `e.get("kind", "") == KIND_DELIVERY`. Так же `hour` строкой потом сломает `moment_text` на экране журнала (задача 5).

Рядом: `places` с объектами/`null` (`[{"x":1}, 7, null]`) читаются как три места `"{ \"x\": 1 }"`, `"7"`, `"<null>"` — `places_count()` = 3.

## Предложение
В `_from_dict` брать только записи со строковыми `kind`/`text` и числовым `hour`, в `places` — только строки.
