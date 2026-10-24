#!/usr/bin/env bash

vf_info() { printf 'INFO: %s\n' "$*"; }
vf_warn() { printf 'WARN: %s\n' "$*" >&2; }
vf_error() { printf 'ERROR: %s\n' "$*" >&2; }
vf_die() { vf_error "$*"; exit 1; }

vf_command_exists() {
  command -v "$1" >/dev/null 2>&1
}

vf_file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

vf_atomic_write() {
  vf_target=$1
  vf_mode=$2
  vf_target_dir=$(dirname "$vf_target")
  vf_target_base=$(basename "$vf_target")

  [ ! -L "$vf_target" ] || vf_die "refusing to replace symlink: $vf_target"
  VF_ACTIVE_TEMP=$(mktemp "$vf_target_dir/.${vf_target_base}.tmp.XXXXXX") || vf_die "cannot create temporary output"
  chmod "$vf_mode" "$VF_ACTIVE_TEMP"
  cat >"$VF_ACTIVE_TEMP"
  mv -f "$VF_ACTIVE_TEMP" "$vf_target"
  VF_ACTIVE_TEMP=
}

vf_random_hex() {
  vf_bytes=$1
  if vf_command_exists openssl; then
    openssl rand -hex "$vf_bytes"
  elif [ -r /dev/urandom ] && vf_command_exists od && vf_command_exists tr; then
    od -An -N "$vf_bytes" -tx1 /dev/urandom | tr -d ' \n'
  else
    vf_die "secure random generation requires openssl or /dev/urandom with od and tr"
  fi
}

vf_cleanup() {
  if [ -n "${VF_ACTIVE_TEMP:-}" ] && [ -f "$VF_ACTIVE_TEMP" ]; then
    rm -f -- "$VF_ACTIVE_TEMP"
  fi
}

trap vf_cleanup EXIT HUP INT TERM
