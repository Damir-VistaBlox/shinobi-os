#!/usr/bin/env bash
# Build a Shinobi package from its skeleton plus the shared source trees.
# Used by the ISO hook, install.sh and the test suite.
#
#   build-deb.sh <core|desktop|installer> [output.deb]
#   build-deb.sh <core|desktop|installer> --stage <dir>
#
# `--stage` stops after laying out the tree and prints nothing else, so package
# *contents* can be checked on a host with no dpkg-deb. Building the archive
# still needs Debian tooling; asserting what goes into it does not, and the
# contents are where the interesting mistakes are.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

package="${1:-}"
if [[ -z $package ]]; then
  echo "usage: build-deb.sh <core|desktop|installer> [output.deb|--stage dir]" >&2
  exit 64
fi
shift

case "$package" in
  core | desktop | installer) ;;
  *)
    echo "build-deb.sh: unknown package '$package' (expected core, desktop or installer)" >&2
    exit 64
    ;;
esac

stage_only=false
stage=""
output=""
for arg in "$@"; do
  case "$arg" in
    --stage)
      stage_only=true
      ;;
    *)
      output="$arg"
      ;;
  esac
done

if [[ $stage_only == true ]]; then
  if [[ -z ${2:-} ]]; then
    echo "build-deb.sh: --stage needs a directory" >&2
    exit 64
  fi
  stage="$2"
elif [[ -z $output ]]; then
  output="$root/shinobi-$package.deb"
fi

if [[ $stage_only == false ]]; then
  stage="$(mktemp -d)"
  # The stage carries the shipped directory modes, some of which are read-only by
  # design, and rm cannot unlink inside a directory it cannot write.
  trap 'chmod -R u+rwX "$stage" 2>/dev/null; rm -rf "$stage"' EXIT
fi

cp -a "$root/packaging/shinobi-$package/." "$stage/"

case "$package" in
  core)
    # The engine ships in shinobi-core and nowhere else.
    #
    # It was in all three, so that each could call "put the layer on this
    # machine" without a path. dpkg does not allow two packages to own one path:
    # the second install fails with "trying to overwrite
    # /usr/lib/shinobi/shinobi-setup, which is also in package shinobi-core", and
    # it fails *after* the dependency resolution and the postinst, so the image
    # build would have died at the desktop package having got all the way
    # through live-build. One owner, and the other two call it by its absolute
    # path -- which is what the wizard's shellprocess steps already do.
    mkdir -p "$stage/usr/bin" "$stage/usr/share/shinobi/themes" "$stage/usr/share/shinobi/tools" \
      "$stage/usr/share/shinobi/providers"
    cp -a "$root/bin/shinobi" "$root"/bin/shinobi-* "$stage/usr/bin/"
    cp -a "$root/bin/_shinobi-common.sh" "$stage/usr/bin/"
    cp -a "$root/libexec/shinobi/." "$stage/usr/lib/shinobi/"

    # The recon server, as a private copy rather than into dist-packages.
    #
    # It is not a library other code should import: it is the component that
    # enforces the scope gate and writes the audit log, and putting `shinobi_recon`
    # in the system namespace would let a stray `pip install --user` shadow the copy
    # those guarantees live in. Its dependency goes the other way -- `mcp` comes
    # from apt (python3-mcp) and is imported normally -- so nothing here needs
    # debhelper's dh_python3 to compute a dist-packages path, and nothing needs to
    # own the byte-compilation of code it does not ship.
    #
    # The manifests are already above, at /usr/share/shinobi/tools, which the
    # registry prefers over any copy inside the package.
    mkdir -p "$stage/usr/lib/shinobi/mcp-servers"
    cp -a "$root/mcp-servers/shinobi-recon/shinobi_recon" "$stage/usr/lib/shinobi/mcp-servers/"

    # The engine on PATH. It is a libexec script and one package owns it; this is
    # a symlink, not a second copy, so there is still one file on the system and
    # one package responsible for it. Without it, install.sh's `shinobi-setup
    # apply` -- and the documentation -- refer to a command that is not there.
    ln -sfn ../lib/shinobi/shinobi-setup "$stage/usr/bin/shinobi-setup"

    cp -a "$root/themes/." "$stage/usr/share/shinobi/themes/"
    cp -a "$root/tools/." "$stage/usr/share/shinobi/tools/"
    cp -a "$root/providers/." "$stage/usr/share/shinobi/providers/"
    ;;
  desktop)
    # The dotfiles, wallpaper, Plymouth theme and portal configuration are
    # already in packaging/shinobi-desktop, which is the only copy: they used to
    # live in the ISO's includes.chroot, where nothing installed them onto a
    # disk.
    ;;
  installer)
    # The wizard's configuration and branding are already in
    # packaging/shinobi-installer, for the same reason.
    ;;
esac

# Bytecode caches are not source. They appear the moment anyone imports these
# modules, which the test suite does, so without this the .deb silently depends
# on whether the builder happened to run the tests first -- a clean checkout and
# a dirty one produce different packages. They are also built for the builder's
# Python and architecture, not the target's.
find "$stage" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$stage" -type f -name '*.pyc' -delete

chmod 0755 "$stage/usr/lib/shinobi"/* 2>/dev/null || true
if [[ -d "$stage/usr/local/bin" ]]; then
  chmod 0755 "$stage/usr/local/bin"/* 2>/dev/null || true
fi
if [[ $package == core ]]; then
  chmod 0755 "$stage/usr/bin"/shinobi "$stage/usr/bin"/shinobi-* "$stage/usr/bin/_shinobi-common.sh"
fi

if [[ $stage_only == true ]]; then
  exit 0
fi

# --root-owner-group, because dpkg-deb otherwise records whatever owns the
# staged files -- which is whoever ran the build. install.sh builds from a user
# checkout, so without this every file in the package lands owned by that user:
# /usr/bin/shinobi-recon, the systemd user units, /etc/shinobi. A uid 1000
# account that can rewrite the entry point `shinobi agent` executes is not a
# packaging nit, and the ISO hook hid the bug by building as root.
dpkg-deb --root-owner-group --build "$stage" "$output" >/dev/null
echo "$output"