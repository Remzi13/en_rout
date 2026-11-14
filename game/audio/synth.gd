class_name Synth
extends RefCounted
## Процедурные звуки-заглушки (AudioStreamWAV, 16 бит моно). Создаются
## один раз и кэшируются. Чтобы заменить на настоящие записи — верните
## из нужной функции загруженный ресурс.

const RATE := 22050

static var _cache: Dictionary = {}


static func engine_loop() -> AudioStreamWAV:
	return _cached("engine", func() -> AudioStreamWAV:
		var n := RATE / 2 # 0.5 с = ровно 30 периодов 60 Гц
		var s := PackedFloat32Array()
		s.resize(n)
		for i in n:
			var t := float(i) / RATE
			var w := TAU * 60.0 * t
			var v := 0.0
			for k in range(1, 8):
				v += sin(w * k + k * 0.7) / pow(k, 0.9)
			v += 0.35 * signf(sin(w * 0.5)) # «рокот» на полчастоты
			s[i] = v * 0.16
		return _wav(s, true))


static func tire_loop() -> AudioStreamWAV:
	return _cached("tire", func() -> AudioStreamWAV:
		var n := RATE
		var s := PackedFloat32Array()
		s.resize(n)
		var rng := RandomNumberGenerator.new()
		rng.seed = 3
		var lp := 0.0
		for i in n:
			lp = lerpf(lp, rng.randf_range(-1.0, 1.0), 0.35)
			var t := float(i) / RATE
			s[i] = (lp * 0.6 + sin(TAU * 880.0 * t) * 0.15 * (0.6 + 0.4 * sin(TAU * 6.0 * t))) * 0.7
		return _wav(s, true))


static func impact() -> AudioStreamWAV:
	return _cached("impact", func() -> AudioStreamWAV:
		var n := int(RATE * 0.45)
		var s := PackedFloat32Array()
		s.resize(n)
		var rng := RandomNumberGenerator.new()
		rng.seed = 4
		var lp := 0.0
		for i in n:
			var t := float(i) / RATE
			lp = lerpf(lp, rng.randf_range(-1.0, 1.0), 0.25)
			s[i] = (lp * exp(-t * 9.0) + sin(TAU * 70.0 * t) * exp(-t * 12.0)) * 0.9
		return _wav(s, false))


static func alert() -> AudioStreamWAV:
	return _cached("alert", func() -> AudioStreamWAV:
		return _tones([[660.0, 0.16], [880.0, 0.16], [660.0, 0.16], [880.0, 0.3]], 0.5))


static func success() -> AudioStreamWAV:
	return _cached("success", func() -> AudioStreamWAV:
		return _tones([[523.0, 0.12], [659.0, 0.12], [784.0, 0.12], [1047.0, 0.4]], 0.45))


static func fail() -> AudioStreamWAV:
	return _cached("fail", func() -> AudioStreamWAV:
		return _tones([[440.0, 0.2], [370.0, 0.2], [311.0, 0.2], [220.0, 0.5]], 0.45))


static func whoosh() -> AudioStreamWAV:
	return _cached("whoosh", func() -> AudioStreamWAV:
		var n := int(RATE * 0.5)
		var s := PackedFloat32Array()
		s.resize(n)
		var rng := RandomNumberGenerator.new()
		rng.seed = 8
		var lp := 0.0
		for i in n:
			var t := float(i) / RATE
			lp = lerpf(lp, rng.randf_range(-1.0, 1.0), 0.1 + 0.3 * t)
			s[i] = lp * sin(PI * t / 0.5) * 0.9
		return _wav(s, false))


## Простая музыкальная петля погони: бас + хэт, 8 тактов по 4 доли, 140 BPM.
static func chase_music() -> AudioStreamWAV:
	return _cached("chase_music", func() -> AudioStreamWAV:
		var beat := 60.0 / 140.0
		var n := int(RATE * beat * 32.0)
		var s := PackedFloat32Array()
		s.resize(n)
		var rng := RandomNumberGenerator.new()
		rng.seed = 11
		var bass := [55.0, 55.0, 65.4, 49.0, 55.0, 55.0, 73.4, 61.7]
		for i in n:
			var t := float(i) / RATE
			var b := int(t / beat)
			var tb := fmod(t, beat)
			var f: float = bass[(b / 4) % bass.size()]
			var env := exp(-tb * 5.0)
			var saw := fmod(t * f, 1.0) * 2.0 - 1.0
			var v := saw * env * 0.35
			var half := fmod(t, beat * 0.5)
			v += rng.randf_range(-1.0, 1.0) * exp(-half * 60.0) * 0.12
			if b % 2 == 0:
				v += sin(TAU * 50.0 * tb) * exp(-tb * 18.0) * 0.5
			s[i] = v
		return _wav(s, true))


## Проигрывает разовый звук на шине SFX и удаляет плеер после окончания.
static func play(parent: Node, stream: AudioStream, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.bus = &"SFX"
	p.volume_db = volume_db
	p.pitch_scale = pitch
	parent.add_child(p)
	p.finished.connect(p.queue_free)
	p.play()


static func _cached(key: String, maker: Callable) -> AudioStreamWAV:
	if not _cache.has(key):
		_cache[key] = maker.call()
	return _cache[key]


static func _tones(notes: Array, gain: float) -> AudioStreamWAV:
	var s := PackedFloat32Array()
	for note in notes:
		var f: float = note[0]
		var dur: float = note[1]
		var n := int(RATE * dur)
		for i in n:
			var t := float(i) / RATE
			var env := minf(t / 0.01, 1.0) * exp(-t * 3.0)
			s.append((sin(TAU * f * t) + 0.3 * sin(TAU * f * 2.0 * t)) * env * gain)
	return _wav(s, false)


static func _wav(samples: PackedFloat32Array, loop: bool) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = bytes
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = samples.size()
	return w
