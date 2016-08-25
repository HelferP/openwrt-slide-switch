#!/bin/sh
# Copyright (C) 2016 Jeffery To

version=0.9.0

platform_info=/usr/lib/slide-switch/platform.sh
state_dir=/var/run/slide-switch
lock_dir=/var/lock/slide-switch

gpio_table=/sys/kernel/debug/gpio
hotplug_call=/sbin/hotplug-call
rc_button=/etc/rc.button

switches_cache="$state_dir/switches"
state_file="$state_dir/state"

. /usr/share/libubox/jshn.sh

[ -f "$switches_cache" ] || [ ! -f "$platform_info" ] || . "$platform_info"

case $VERBOSITY in
	emerg)		VERBOSITY=0 ;;
	alert)		VERBOSITY=1 ;;
	crit)		VERBOSITY=2 ;;
	err)		VERBOSITY=3 ;;
	warning)	VERBOSITY=4 ;;
	notice)		VERBOSITY=5 ;;
	info)		VERBOSITY=6 ;;
	debug)		VERBOSITY=7 ;;

	''|*[!0-9]*)	VERBOSITY=4 ;;
esac

ex_usage=64
ex_dataerr=65
ex_noinput=66
ex_unavailable=69
ex_tempfail=75

locks=


log() {
	local level="$1"
	local message="$2"

	[ "$level" -le "$VERBOSITY" ] && logger -t "slide-switch[$$]" -p "user.$level" "$message"
	return 0
}

error() {
	local message="$1"
	local exitTrue="$2"

	log 3 "$message"

	[ -n "$exitTrue" ]
}

warning() {
	local message="$1"
	local exitTrue="$2"

	log 4 "$message"

	[ -n "$exitTrue" ]
}

debug() {
	local message="$1"

	log 7 "$message"
}

get_epoch() {
	echo "$(date -u +%s)"
}

get_json_value() {
	local key="$1"
	local var

	json_get_var var "$key" && echo "$var"
}

list_contains() {
	local list=" $1 "
	local item=" $2 "

	[ "${list%$item*}" != "$list" ]
}


get_gpio_info() {
	local gpio="$1"
	local row="$(grep -e "^ *gpio-$gpio\b" "$gpio_table")"

	echo "${row##*)}"
}

get_gpio_value() {
	local gpio="$1"
	local info="$(get_gpio_info "$gpio")"
	local value="lo"

	list_contains "$info" hi && value=hi
	echo "$value"
}

get_position_code() {
	local switch="$1"
	local position_name="$2"

	echo "${switch}-$position_name"
}


check_json_type() {
	local key="$1"
	local type="$2"
	local label="${3:-$key}"
	local article="a"

	case $type in
		[aeiou]*) article=an ;;
	esac

	json_is_a "$key" "$type" || error "\"$label\" is not $article $type in $switch_data_file"
}

check_input_gpio() {
	local gpio="$1"
	local info="$(get_gpio_info "$gpio")"

	list_contains "$info" "in" || error "\"$gpio\" is not a valid input gpio"
}

check_position_string() {
	local position="$1"
	local str="$position"
	local prev

	while [ "$str" != "$prev" ]; do
		prev=$str

		str=${str%_hi}
		str=${str%_lo}
	done

	[ "$str" = hi ] || [ "$str" = lo ] || warning "position \"$position\" is not in the format \"(hi|lo)(_(hi|lo))*\""
}

check_nonempty_string() {
	local str="$1"
	local label="$2"

	[ -n "$str" ] || error "$label cannot be an empty string"
}

check_safe_string() {
	local str="$1"
	local label="$2"

	[ "${str%[!0-9A-Za-z_-]*}" = "$str" ] || error "$label \"$str\" must contain letters, digits, underscores and/or hyphens only"
}

check_position_code() {
	local switch="$1"
	local position_name="$2"
	local codes="$3"
	local code="$(get_position_code "$switch" "$position_name")"

	! list_contains "$codes" "$code" || error "switch \"$switch\" cannot have both a position name \"$position_name\" and a code \"$code\""
}

validate_switch_data() {
	local switches
	local switch
	local gpios
	local gpio
	local codes
	local positions
	local position
	local position_name

	json_set_namespace switches
	json_select

	json_get_keys switches

	[ -n "$switches" ] || warning "no switches defined for \"$board_name\""

	for switch in $switches; do
		check_json_type "$switch" object || return

		json_select "$switch"

		check_json_type gpios array "$switch.gpios" &&
		check_json_type codes array "$switch.codes" &&
		check_json_type positions object "$switch.positions" || return

		json_get_values gpios gpios
		json_get_values codes codes

		[ -n "$gpios" ] || warning "no gpios defined for switch \"$switch\""
		[ -n "$codes" ] || warning "no codes defined for switch \"$switch\""

		for gpio in $gpios; do
			check_input_gpio "$gpio" || return
		done

		json_select positions

		json_get_keys positions

		[ -n "$positions" ] || warning "no positions defined for switch \"$switch\""

		for position in $positions; do
			check_position_string "$position" || continue

			check_json_type "$position" string "$switch.positions.$position" || return

			json_get_var position_name "$position"

			check_nonempty_string "$position_name" "$switch.position.$position" &&
			check_safe_string "$position_name" "position name" &&
			check_position_code "$switch" "$position_name" "$codes" || return
		done

		json_select
	done
}

load_switch_data() {
	local board="$board_name"
	local type
	local data

	[ -f "$switches_cache" ] && {
		debug "loading switch data from $switches_cache"
		json_set_namespace switches
		json_load "$(cat "$switches_cache")"
		return
	}

	[ -f "$platform_info" ] || warning "$platform_info missing, this does not appear to be a supported platform" || return $ex_unavailable

	[ -n "$board" ] || error "missing board name" || return $ex_dataerr
	[ -f "$switch_data_file" ] || error "cannot find switch data file \"$switch_data_file\"" || return $ex_noinput

	debug "attemping to load switch data for $board from $switch_data_file"

	jsonfilter -q -i "$switch_data_file" -t "@"
	[ "$?" -ne 126 ] || error "failed to parse $switch_data_file" || return $ex_dataerr

	type=$(jsonfilter -i "$switch_data_file" -t "@[\"$board\"]")

	[ "$type" = string ] && {
		debug "$board shares switch data with another board, loading alternate board name"
		board=$(jsonfilter -i "$switch_data_file" -e "@[\"$board\"]")

		[ -n "$board" ] || error "missing alternate board name" || return $ex_dataerr

		type=$(jsonfilter -i "$switch_data_file" -t "@[\"$board\"]")
	}

	case $type in
		object)
			debug "loading switch data for $board from $switch_data_file"
			data=$(jsonfilter -i "$switch_data_file" -e "@[\"$board\"]")
			;;
		'')
			warning "\"$board\" not found in $switch_data_file"
			return $ex_unavailable
			;;
		*)
			error "\"$board\" is not an object in $switch_data_file"
			return $ex_dataerr
			;;
	esac

	json_set_namespace switches
	json_load "$data"

	validate_switch_data || return $ex_dataerr

	debug "caching switch data to $switches_cache"
	mkdir -p "$(dirname "$switches_cache")"
	echo "$data" > "$switches_cache"
}


get_switches() {
	local switches

	json_set_namespace switches
	json_select

	json_get_keys switches
	echo "$switches"
}

get_switch_for_button() {
	local button="$1"
	local switches
	local switch
	local codes

	json_set_namespace switches
	json_select

	json_get_keys switches
	for switch in $switches; do
		json_select "$switch"
		json_get_values codes codes

		list_contains "$codes" "$button" && {
			debug "found switch \"$switch\" for button \"$button\""
			echo "$switch"
			return
		}

		json_select ..
	done

	debug "no switches found for button \"$button\""
	return 1
}

get_current_position() {
	local switch="$1"
	local gpios
	local gpio
	local position

	json_set_namespace switches
	json_select
	json_select "$switch"

	json_get_values gpios gpios
	for gpio in $gpios; do
		position="${position}_$(get_gpio_value "$gpio")"
	done
	position=${position#_}

	echo "$position"
}

get_position_name() {
	local switch="$1"
	local position="$2"
	local position_name

	json_set_namespace switches
	json_select
	json_select "$switch"
	json_select positions

	json_get_var position_name "$position" || warning "position \"$position\" for switch \"$switch\" does not have a position name" || return

	echo "$position_name"
}


init_state() {
	local now="$(get_epoch)"
	local switches="$(get_switches)"
	local switch
	local positions
	local position

	debug "initializing state"
	json_set_namespace state
	json_init

	for switch in $switches; do
		position=$(get_current_position "$switch")

		json_set_namespace switches
		json_select
		json_select "$switch"
		json_get_keys positions positions

		debug "setting \"$position\" as initial position for switch \"$switch\""

		json_set_namespace state
		json_select
		json_add_object "$switch"
		json_add_string position "$position"
		json_add_object seen
		for position in $positions; do
			json_add_int "$position" "$now"
		done
		json_close_object
		json_close_object
	done
}

load_state() {
	debug "attempting to load state from $state_file"
	[ -f "$state_file" ] && {
		debug "loading state from $state_file"
		json_set_namespace state
		json_load "$(cat "$state_file")"
	}
}

save_state() {
	debug "saving state to $state_file"
	json_set_namespace state
	mkdir -p "$(dirname "$state_file")"
	echo "$(json_dump)" > "$state_file"
}


get_state_position() {
	local switch="$1"

	json_set_namespace state
	json_select
	json_select "$switch"
	echo "$(get_json_value position)"
}

set_state_position() {
	local switch="$1"
	local position="$2"

	json_set_namespace state
	json_select
	json_select "$switch"
	json_add_string position "$position"
}

get_state_seen() {
	local switch="$1"
	local position="$2"

	json_set_namespace state
	json_select
	json_select "$switch"
	json_select seen
	echo "$(get_json_value "$position")"
}

set_state_seen() {
	local switch="$1"
	local position="$2"
	local seen="$3"

	json_set_namespace state
	json_select
	json_select "$switch"
	json_select seen
	json_add_int "$position" "$seen"
}


get_lock_dir() {
	local switch="$1"

	echo "$lock_dir/$switch.lock"
}

cleanup_locks() {
	local switch
	local dir

	for switch in $locks; do
		dir="$(get_lock_dir "$switch")"
		debug "attempting to remove $dir"
		[ -d "$dir" ] && {
			debug "removing $dir"
			rm -rf "$dir"
		}
	done

	locks=
}

get_lock() {
	local switch="$1"
	local dir="$(get_lock_dir "$switch")"

	mkdir -p "$lock_dir"

	mkdir "$dir" 2>/dev/null || {
		debug "failed to get lock for $switch ($dir)"
		return 1
	}

	locks="$locks $switch"

	trap 'cleanup_locks' EXIT
	trap 'cleanup_locks; trap - INT; kill -INT $$' INT
	trap 'exit 129' HUP
	trap 'exit 131' QUIT
	trap 'exit 143' TERM

	debug "got lock for $switch ($dir)"
}

release_locks() {
	debug "releasing locks"

	cleanup_locks

	trap - EXIT INT HUP QUIT TERM
}


trigger_button_event() {
	local switch="$1"
	local position="$2"
	local action="$3"
	local now="$4"
	local position_name="$(get_position_name "$switch" "$position")"
	local before
	local button
	local seen

	[ -n "$position_name" ] || warning "could not get position name for switch \"$switch\" and position \"$position\"" || return

	before=$(get_state_seen "$switch" "$position")
	[ -n "$now" ] || now=$before
	set_state_seen "$switch" "$position" "$now"

	button=$(get_position_code "$switch" "$position_name")
	seen=$(($now - $before))

	(
		export BUTTON="$button"
		export ACTION="$action"
		export SEEN="$seen"

		debug "triggering button event with BUTTON=\"$button\" ACTION=\"$action\" SEEN=\"$seen\""

		debug "attemping to call $hotplug_call"
		[ -x "$hotplug_call" ] && "$hotplug_call" button

		debug "attempting to call $rc_button/$button"
		[ -x "$rc_button/$button" ] && "$rc_button/$button"
	)
}

do_init() {
	local switches
	local switch
	local position

	debug "do_init"

	load_switch_data || return

	switches=$(get_switches)

	for switch in $switches; do
		get_lock "$switch" || {
			release_locks
			return $ex_tempfail
		}
	done

	init_state
	save_state

	for switch in $switches; do
		position=$(get_state_position "$switch")
		trigger_button_event "$switch" "$position" pressed
	done

	release_locks
}

do_button() {
	local button="$1"
	local has_previous="1"
	local switch
	local current
	local previous
	local now
	local position_name
	local before

	debug "do_button \"$button\""

	load_switch_data || return

	switch=$(get_switch_for_button "$button") && get_lock "$switch" || return $ex_tempfail

	sleep 1

	load_state || {
		init_state
		has_previous=
	}

	if [ -n "$has_previous" ]; then
		previous=$(get_state_position "$switch")
		debug "previous position for switch \"$switch\" is \"$previous\""
	else
		debug "no previous position for switch \"$switch\""
	fi

	current=$(get_current_position "$switch")
	debug "current position for switch \"$switch\" is \"$current\""

	[ "$current" != "$previous" ] || {
		debug "switch \"$switch\" position unchanged"
		return $ex_tempfail
	}

	now="$(get_epoch)"

	[ -n "$has_previous" ] && trigger_button_event "$switch" "$previous" released "$now"
	trigger_button_event "$switch" "$current" pressed "$now"

	set_state_position "$switch" "$current"
	save_state

	release_locks
}

do_version() {
	echo "$version"
}
