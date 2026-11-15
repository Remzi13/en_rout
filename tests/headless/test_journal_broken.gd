extends SceneTree
## Битые и странные файлы журнала: игра не падает, журнал читается или
## начинается заново, сводка stats() и подсчёты работают, файл потом
## нормально перезаписывается. Пишет в user://test_journal_broken.json.

const H := preload("res://tests/headless/helper.gd")
const PATH := "user://test_journal_broken.json"

const CASES := {
	"пустой файл": "",
	"мусор": "ъъъ\u0001\u0002 not json {{{",
	"{}": "{}",
	"[]": "[]",
	"null": "null",
	"число": "42",
	"version: null": "{\"version\": null}",
	"version: массив": "{\"version\": [1]}",
	"version: строка": "{\"version\": \"один\"}",
	"version 2 (будущая)": "{\"version\": 2, \"stats\": {\"distance_m\": 5000}}",
	"stats строкой": "{\"version\": 1, \"stats\": \"много\"}",
	"stats с текстом": "{\"version\": 1, \"stats\": {\"distance_m\": \"abc\", \"drive_time_s\": null}}",
	"записи не словари": "{\"version\": 1, \"entries\": [1, \"a\", null]}",
	"kind и hour числом/строкой": "{\"version\": 1, \"entries\": [{\"kind\": 5, \"hour\": \"вечер\"}, {\"kind\": null}]}",
	"places словарём": "{\"version\": 1, \"places\": {\"a\": 1}}",
	"places с объектами": "{\"version\": 1, \"places\": [{\"x\": 1}, 7, null]}",
	"обрезанный файл": "{\"version\": 1, \"entries\": [{\"kind\": \"delivery\", \"te",
}


func _initialize() -> void:
	_run()


func _write(text: String) -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _run() -> void:
	for name: String in CASES:
		_write(CASES[name])
		var j := Journal.load_or_new(PATH)
		var ok := j != null
		if ok:
			var s := j.stats()
			ok = s.has("distance_km") and j.deliveries_count() >= 0 and j.places_count() >= 0
			j.add_drive(1.0, 10.0, true, true)
			ok = ok and j.save()
			var again := Journal.load_or_new(PATH)
			ok = ok and is_equal_approx(again.distance_m, j.distance_m)
		H.check("журнал не падает: " + name, ok, "км %.3f, записей %d, мест %d" % [j.distance_m / 1000.0, j.entries.size(), j.places_count()] if j != null else "null")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	H.finish(self)
