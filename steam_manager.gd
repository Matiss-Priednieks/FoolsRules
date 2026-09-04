extends Node
## Autoload singleton. Single entry point for everything Steam.
##
## The game must run BOTH standalone and through Steam, so nothing here may hard
## depend on the GodotSteam extension being present. When the extension isn't
## loaded / Steam isn't running, `available` stays false and every helper is a
## safe no-op - the rest of the game is unchanged.
##
## All Steam calls go through the `_steam` singleton object fetched at runtime
## (never the bare `Steam` identifier) so this script still parses if the
## `addons/godotsteam/` folder is removed for a non-Steam build.
##
## GodotSteam GDExtension v4.22 (Godot 4.4+):
##   steamInitEx(app_id, embed_callbacks) -> {status, verbal}   (status 0 == OK)
##   requestUserStats(steam_id) -> fires `user_stats_received(game, result, user)`
## This build's embedded callback loop doesn't fire, so we pump run_callbacks()
## ourselves every frame.

## Steam App ID. 480 = "Spacewar", Steam's public test app - use it until durak
## has a real App ID (needs the $100 Steam Direct fee). The same number must be in
## `steam_appid.txt` in the project root for editor / headless runs.
const APP_ID := 480

## Emitted once init resolves, whether or not Steam actually came up.
signal steam_ready(available: bool)
## Steam overlay opened/closed - the game should pause while it's open.
signal overlay_toggled(active: bool)

var available := false
var steam_id: int = 0
var persona_name := ""
var stats_ready := false

var _steam: Object = null


func _ready() -> void:
	if not Engine.has_singleton("Steam"):
		push_warning("[Steam] GodotSteam extension not present - running standalone.")
		steam_ready.emit(false)
		return

	_steam = Engine.get_singleton("Steam")

	var res: Dictionary = _steam.steamInitEx(APP_ID, false)
	if int(res.get("status", 1)) != 0:
		push_warning("[Steam] init failed (%s) - running standalone." % res.get("verbal", res))
		_steam = null
		steam_ready.emit(false)
		return

	available = true
	process_mode = Node.PROCESS_MODE_ALWAYS  # keep pumping callbacks even when the tree is paused
	steam_id = int(_steam.getSteamID())
	persona_name = str(_steam.getPersonaName())
	print("[Steam] ready as %s (%d)" % [persona_name, steam_id])

	_steam.connect("user_stats_received", _on_user_stats_received)
	_steam.connect("overlay_toggled", _on_overlay_toggled)
	_steam.requestUserStats(steam_id)  # -> user_stats_received; needed before setAchievement

	steam_ready.emit(true)


func _process(_delta: float) -> void:
	if available:
		_steam.run_callbacks()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if available and _steam != null and _steam.has_method("steamShutdown"):
			_steam.steamShutdown()


# --- Stats / achievements ---------------------------------------------------
# Define the API names on the Steamworks partner site first. With App ID 480 the
# calls run but only Spacewar's built-in achievements actually exist.

func unlock(api_name: String) -> void:
	if not available:
		return
	var cur: Variant = _steam.getAchievement(api_name)
	if cur is Dictionary and cur.get("achieved", false):
		return
	if _steam.setAchievement(api_name):
		_steam.storeStats()


func clear_achievement(api_name: String) -> void:
	if not available:
		return
	_steam.clearAchievement(api_name)
	_steam.storeStats()


## Add `delta` to an INT stat (e.g. lifetime games, wins).
func add_stat(api_name: String, delta: int) -> void:
	if not available:
		return
	_steam.setStatInt(api_name, int(_steam.getStatInt(api_name)) + delta)
	_steam.storeStats()


## Raise an INT stat to `value` only if it's a new high.
func set_stat_max(api_name: String, value: int) -> void:
	if not available:
		return
	if value > int(_steam.getStatInt(api_name)):
		_steam.setStatInt(api_name, value)
		_steam.storeStats()


## Dev helper - wipe all stats + achievements for the local user.
func reset_all_stats() -> void:
	if not available:
		return
	_steam.resetAllStats(true)
	_steam.storeStats()


# --- Overlay --------------------------------------------------------------

func open_overlay(to: String = "") -> void:
	if available:
		_steam.activateGameOverlay(to)


func overlay_enabled() -> bool:
	return available and bool(_steam.isOverlayEnabled())


# --- Multiplayer -------------------------------------------------------------
# Lobby creation / join and the Steam P2P transport for DurakGame intents land
# here next. Kept out of this file until the netcode design is settled; a
# separate `steam_lobby.gd` autoload is the likely home.


# --- Callbacks -------------------------------------------------------------

func _on_user_stats_received(_game: int, result: int, _user: int) -> void:
	if result == 1:  # k_EResultOK
		stats_ready = true


func _on_overlay_toggled(active: bool, _user_initiated: bool = false, _app_id: int = 0) -> void:
	overlay_toggled.emit(active)


# --- Dev status probe (debug builds only) --------------------------------
# F9 : print Steam status. Remove once there's a real in-game diagnostics view.

func _unhandled_key_input(event: InputEvent) -> void:
	if not OS.is_debug_build() or not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	if key.keycode == KEY_F9:
		print("[Steam] available=%s id=%d name=%s overlay_enabled=%s stats_ready=%s"
			% [available, steam_id, persona_name, overlay_enabled(), stats_ready])
