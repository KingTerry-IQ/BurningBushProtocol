## The fire, heard rather than seen.
##
## Synthesised sample by sample instead of shipped as an audio file: a fire is
## filtered noise, and generating it costs nothing on disk, never loops audibly,
## and never repeats itself. A seamless ambient loop long enough not to annoy
## would be megabytes.
##
## Three layers, which is all a fire really is:
##
##   Roar     brown noise, low-passed. The body of it.
##   Hiss     white noise, quiet. Air and steam.
##   Crackle  sparse impulses with a fast decay. The bit the ear listens for.
##
## The whole thing is tied to the flame's state, so it is a status display you
## can hear: full when the covenant is safe, thin and cooling when it is
## overdue, silent when it has gone out.

class_name FireSound
extends AudioStreamPlayer

## Fire is nearly all low and mid content, so half the usual rate is plenty and
## halves the samples GDScript has to produce.
const MIX_RATE := 22050.0
const BUFFER_SECONDS := 0.25

## Ambient, not a foreground effect. Quiet enough to forget it is on.
## The bed sits well under the limiter so crackles keep their bite; a louder
## bed just saturates into flat hiss.
const BASE_VOLUME_DB := -16.0
## How quickly the level follows a change of state, in units per second.
const FADE_RATE := 0.8

## Chance per sample of a crackle starting. Sparse on purpose — evenly spaced
## pops read as machinery, not burning wood.
const CRACKLE_CHANCE := 0.00016

var _playback: AudioStreamGeneratorPlayback
var _rng := RandomNumberGenerator.new()

## Target and current intensity, 0 (silent) to 1 (roaring).
var _target := 0.0
var _level := 0.0

## The cold counterpart, on its own fade so the two cross over rather than one
## cutting out before the other starts.
var _target_wind := 0.0
var _wind_level := 0.0

# Filter and generator state, carried between buffers so there is no seam.
var _brown := 0.0
var _low := 0.0
var _low_right := 0.0
var _crackle := 0.0
var _crackle_tone := 0.0
var _breath := 0.0

# Wind runs a much darker filter and a slower, deeper swell than the fire.
var _wind_low := 0.0
var _wind_low_right := 0.0
var _gust := 0.0


func _ready() -> void:
	_rng.randomize()

	var generator := AudioStreamGenerator.new()
	generator.mix_rate = MIX_RATE
	generator.buffer_length = BUFFER_SECONDS
	stream = generator
	volume_db = BASE_VOLUME_DB

	play()
	_playback = get_stream_playback()
	# Headless and audio-less machines have no playback; stay quiet rather than
	# erroring on every frame.
	set_process(_playback != null)


## Sets what the room sounds like, from the flame's own state.
##
## A dark bush is not silent, it is cold: the fire gives way to thin wind. That
## is a more honest signal than nothing at all, which is indistinguishable from
## the sound being broken or muted.
func set_state(state: Flame.State) -> void:
	match state:
		Flame.State.BURNING:
			_target = 1.0
			_target_wind = 0.0
		Flame.State.GUTTERING:
			_target = 0.45
			# A guttering flame lets a little of the cold in behind it.
			_target_wind = 0.25
		Flame.State.DARK, Flame.State.NEVER_LIT:
			_target = 0.0
			_target_wind = 1.0
		_:
			# Unreadable: nothing to represent, so nothing to hear.
			_target = 0.0
			_target_wind = 0.0


## Whether this state makes any sound at all. A mute switch for something
## already silent is a control over nothing, so the UI uses this to decide
## whether to offer one. Only an unreadable flame is truly silent.
static func audible_at(state: Flame.State) -> bool:
	return state != Flame.State.UNKNOWN


## Silences it without tearing down the generator, for a mute toggle.
func set_enabled(enabled: bool) -> void:
	if enabled:
		if not playing:
			play()
			_playback = get_stream_playback()
		set_process(_playback != null)
	else:
		set_process(false)
		stop()
		_level = 0.0


func _process(delta: float) -> void:
	if _playback == null:
		return

	_level = move_toward(_level, _target, FADE_RATE * delta)
	_wind_level = move_toward(_wind_level, _target_wind, FADE_RATE * delta)
	if _level <= 0.0 and _target <= 0.0 and _wind_level <= 0.0 and _target_wind <= 0.0:
		# Still push silence: leaving the buffer starved makes the driver
		# repeat whatever it last had.
		_push_silence()
		return

	var frames := _playback.get_frames_available()
	if frames <= 0:
		return

	var buffer := PackedVector2Array()
	buffer.resize(frames)

	for i in frames:
		buffer[i] = _next_sample()

	_playback.push_buffer(buffer)


func _push_silence() -> void:
	var frames := _playback.get_frames_available()
	if frames <= 0:
		return
	var buffer := PackedVector2Array()
	buffer.resize(frames)
	_playback.push_buffer(buffer)


## One stereo sample. Everything here is a first-order filter or a decaying
## envelope — no tables, no allocations.
func _next_sample() -> Vector2:
	var white := _rng.randfn(0.0, 0.35)

	# Brown noise: integrate white and leak, which tilts the spectrum downward
	# and gives the roar its weight.
	_brown = (_brown + 0.03 * white) * 0.994

	# Two low passes at slightly different cutoffs, one per channel, so the bed
	# is decorrelated and sounds wide rather than like a mono buzz.
	_low += (_brown - _low) * 0.10
	_low_right += (_brown - _low_right) * 0.13

	# A fire breathes. Slow random walk rather than a sine, which would beat
	# audibly against itself.
	_breath = clampf(_breath + _rng.randfn(0.0, 0.004), -0.35, 0.35)
	var swell := 1.0 + _breath

	# Crackles: a fast-decaying envelope on a high, slightly pitched click.
	if _rng.randf() < CRACKLE_CHANCE * _level:
		_crackle = _rng.randf_range(0.35, 1.3)
		_crackle_tone = _rng.randf_range(0.3, 0.9)
	_crackle *= 0.9985
	var pop := _crackle * white * _crackle_tone

	var hiss := white * 0.035

	var left := (_low * 1.2 + hiss + pop) * swell * _level
	var right := (_low_right * 1.2 + hiss * 0.9 + pop * 0.8) * swell * _level

	if _wind_level > 0.0:
		# Far darker filtering than the fire, and no crackle at all — what is
		# left when there is nothing burning is air moving over cold ground.
		_wind_low += (_brown - _wind_low) * 0.030
		_wind_low_right += (_brown - _wind_low_right) * 0.038
		# Gusts: a slower, wider random walk than the fire's breath.
		_gust = clampf(_gust + _rng.randfn(0.0, 0.0015), -0.6, 0.75)
		var gusting := (1.0 + _gust) * _wind_level
		left += (_wind_low * 0.7 + white * 0.018) * gusting
		right += (_wind_low_right * 0.7 + white * 0.015) * gusting

	# Soft clip: a fire never spikes, and this keeps stray peaks from cracking.
	return Vector2(_soft(left), _soft(right))


static func _soft(value: float) -> float:
	if value > 1.0 or value < -1.0:
		return signf(value) * (1.0 - 1.0 / (absf(value) + 1.0)) * 2.0 - signf(value)
	return value - (value * value * value) / 3.0
