#!/usr/bin/env bash
# Карта из Blender -> чанки игры. Запуск из любого места:
#   tools/export_map.sh
#   BLENDER=/путь/к/blender GODOT=/путь/к/godot tools/export_map.sh
# 1) Blender снимает с art/map/map.blend высоты, маски, дороги, старт, объекты Props,
#    места Places и точки доставок Spots
#    (tools/blender/export_map.py -> art/map/export/);
# 2) Godot режет карту на чанки (tools/bake_world.gd -> game/world/chunks/,
#    world.tscn, world_index.tres). Чанки перезаписываются целиком.
# Godot запускается с окном: в headless растительность не сохраняется.
set -euo pipefail
cd "$(dirname "$0")/.."
BLENDER="${BLENDER:-/home/rmz/blender/blender}"
GODOT="${GODOT:-/home/rmz/Godot472/Godot_v4.7.2-stable_linux.x86_64}"
if [ ! -x "$BLENDER" ]; then BLENDER="$(command -v blender || true)"; fi
if [ ! -x "$GODOT" ]; then GODOT="$(command -v godot4 || command -v godot || true)"; fi
if [ -z "$BLENDER" ] || [ -z "$GODOT" ]; then echo "Не найден Blender или Godot: задайте BLENDER=... GODOT=..."; exit 2; fi

# Старый map.json удаляем: если экспорт упадёт, Godot не запечёт прошлую карту.
rm -f art/map/export/map.json
if ! out="$("$BLENDER" --background art/map/map.blend --python-exit-code 1 --python tools/blender/export_map.py 2>&1)" \
		|| [ ! -f art/map/export/map.json ]; then
	echo "$out" | tail -20
	echo "Экспорт из Blender не удался"
	exit 1
fi
echo "$out" | grep -E "Экспорт|Внимание" || true
"$GODOT" --headless --path . --import >/dev/null 2>&1
"$GODOT" --path . -s res://tools/bake_world.gd 2>&1 | grep -vE "^(Godot Engine|OpenGL|Vulkan)|V-Sync|set_use_vsync|^$"
