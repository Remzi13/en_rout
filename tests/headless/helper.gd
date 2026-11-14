extends RefCounted
## Общие функции headless-тестов (res://tests/headless/). Подключается через
## const H := preload("res://tests/headless/helper.gd").
## Формат вывода: "PASS|FAIL <критерий> — <детали>", итог через finish().

const DT := 1.0 / 60.0

static var failures: int = 0
static var checks: int = 0


static func check(name: String, ok: bool, detail: String = "") -> bool:
	checks += 1
	if not ok:
		failures += 1
	print("%s  %s%s" % ["PASS" if ok else "FAIL", name, (" — " + detail) if detail != "" else ""])
	return ok


static func info(text: String) -> void:
	print("INFO  " + text)


## Печатает итог и завершает процесс: 0 — всё прошло, 1 — были FAIL.
static func finish(tree: SceneTree) -> void:
	print("ИТОГО: проверок %d, провалено %d" % [checks, failures])
	tree.quit(0 if failures == 0 else 1)
