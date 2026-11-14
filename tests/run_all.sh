#!/usr/bin/env bash
# Прогон всех headless-тестов. Использование:
#   tests/run_all.sh                # все тесты
#   GODOT=/путь/к/godot tests/run_all.sh
#   tests/run_all.sh test_respawn   # только тесты, чьё имя содержит подстроку
# Код возврата: 0 — всё прошло, 1 — есть провалы. Логи — tests/.logs/.
set -u
cd "$(dirname "$0")/.."
GODOT="${GODOT:-/home/rmz/Godot472/Godot_v4.7.2-stable_linux.x86_64}"
if [ ! -x "$GODOT" ]; then GODOT="$(command -v godot4 || command -v godot || true)"; fi
if [ -z "$GODOT" ]; then echo "Godot не найден: задайте GODOT=/путь/к/бинарнику"; exit 2; fi
FILTER="${1:-}"
LOGS=tests/.logs
mkdir -p "$LOGS"
rm -f "$LOGS"/*.log "$LOGS"/*.rc

# Первый импорт (создаёт кэш class_name); без него -s скрипты не видят class_name-классы.
"$GODOT" --headless --path . --import >/dev/null 2>&1

run_one() { # имя [доп. аргументы после --]
  local name="$1"; shift
  local log="$LOGS/${name}${1:+_$1}.log"
  timeout 900 "$GODOT" --headless --fixed-fps 60 --path . -s "res://tests/headless/${name}.gd" ${1:+-- "$@"} >"$log" 2>&1
  echo $? >"${log%.log}.rc"
}
export -f run_one
export GODOT LOGS

status=0
# Смоук: главная сцена ~10 с без ERROR / SCRIPT ERROR (предупреждения WARNING не считаются).
if [ -z "$FILTER" ] || [[ "smoke" == *"$FILTER"* ]]; then
  "$GODOT" --headless --fixed-fps 60 --path . --quit-after 600 >"$LOGS/smoke.log" 2>&1
  if grep -qE 'SCRIPT ERROR|^ERROR:' "$LOGS/smoke.log"; then echo 1 >"$LOGS/smoke.rc"; echo "FAIL  смоук: ошибки в логе главной сцены" >>"$LOGS/smoke.log"; else echo 0 >"$LOGS/smoke.rc"; echo "PASS  смоук: главная сцена 600 кадров без ERROR" >>"$LOGS/smoke.log"; fi
fi

for f in tests/headless/test_*.gd; do
  name="$(basename "$f" .gd)"
  [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]] && continue
  run_one "$name"
done

echo "================ СВОДКА ================"
for rc in "$LOGS"/*.rc; do
  [ -e "$rc" ] || continue
  log="${rc%.rc}.log"
  label="$(basename "${rc%.rc}")"
  pass=$(grep -c '^PASS' "$log"); fail=$(grep -c '^FAIL' "$log")
  scripterr=$(grep -cE 'SCRIPT ERROR|^ERROR:' "$log")
  if [ "$(cat "$rc")" = "0" ] && [ "$fail" = "0" ]; then res="OK  "; else res="FAIL"; status=1; fi
  printf '%s %-34s PASS=%-3s FAIL=%-3s ошибок движка/скрипта=%s\n' "$res" "$label" "$pass" "$fail" "$scripterr"
done
echo "--- проваленные проверки ---"
grep -h '^FAIL' "$LOGS"/*.log | cut -c1-220 || true
exit $status
