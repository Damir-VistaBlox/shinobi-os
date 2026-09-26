#!/bin/sh
# Validation for the squashfs settings distro/build.sh hands to live-build.
#
# Sourced, not executed: build.sh interpolates these values into
# kali-live/auto/config, and that file is a bash script live-build runs. An
# unvalidated value containing a double quote is therefore not a bad setting, it
# is a command. live-build's own compression types are a short fixed list, so
# the check is an allowlist rather than a pattern that tries to describe what is
# safe.
#
# Set by shinobi_resolve_squashfs on success:
#   SHINOBI_SQUASHFS_COMPRESSION  one of gzip xz zstd lz4 lzo none
#   SHINOBI_SQUASHFS_LEVEL        an integer, or none

shinobi_resolve_squashfs() {
  _shinobi_compression="${1-}"
  _shinobi_level="${2-}"

  case "$_shinobi_compression" in
    gzip | xz | zstd | lz4 | lzo | none) ;;
    '')
      echo "build: SHINOBI_SQUASHFS_COMPRESSION is empty; expected one of: gzip xz zstd lz4 lzo none" >&2
      return 1
      ;;
    *)
      echo "build: refusing SHINOBI_SQUASHFS_COMPRESSION='$_shinobi_compression'" >&2
      echo "build: expected one of: gzip xz zstd lz4 lzo none" >&2
      return 1
      ;;
  esac

  # live-build's documented ranges top out at 22 (zstd). Matched as patterns
  # rather than compared arithmetically: $((10#<long digit run>)) wraps silently
  # instead of failing, so a 30-digit level came back as a plausible number.
  # Leading zeros are allowed since a config file may well write "03".
  case "$_shinobi_level" in
    none) ;;
    '')
      echo "build: SHINOBI_SQUASHFS_LEVEL is empty; expected an integer 0-22, or none" >&2
      return 1
      ;;
    0 | 0[0-9] | [1-9] | 1[0-9] | 2[0-2]) ;;
    *)
      echo "build: refusing SHINOBI_SQUASHFS_LEVEL='$_shinobi_level'; expected an integer 0-22, or none" >&2
      return 1
      ;;
  esac

  SHINOBI_SQUASHFS_COMPRESSION="$_shinobi_compression"
  SHINOBI_SQUASHFS_LEVEL="$_shinobi_level"
  export SHINOBI_SQUASHFS_COMPRESSION SHINOBI_SQUASHFS_LEVEL
  unset _shinobi_compression _shinobi_level _shinobi_level_num
  return 0
}
