#!/bin/bash
set -euo pipefail

FILE="$(basename "$0")"

# Use all available threads to build a package
sed -i 's/#MAKEFLAGS="-j2"/MAKEFLAGS="-j$(nproc) -l$(nproc)"/g' /etc/makepkg.conf

# Use ccache
sed -i 's/\!ccache/ccache/' /etc/makepkg.conf

# Install base-devel + ccache
pacman -Syu --noconfirm --needed base-devel ccache

# Configure ccache
export CCACHE_DIR="/home/runner/.ccache"
export CCACHE_MAXSIZE="500MB"
export CCACHE_NOHASHDIR="true"
export CCACHE_SLOPPINESS="file_macro,locale,time_macros"
export CCACHE_TEMPDIR="/tmp/ccache"
export PATH="/usr/lib/ccache/bin:$PATH"

# Makepkg does not allow running as root
# Create a new user `builder`
# `builder` needs to have a home directory because some PKGBUILDs will try to
# write to it (e.g. for cache)
useradd runner -m
# When installing dependencies, makepkg will use sudo
# Give user `builder` passwordless sudo access
echo "runner ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Give all users (particularly builder) full access to these files
chmod -R a+rw .

BASEDIR="$PWD"
cd "${INPUT_PKGDIR:-.}"

# Make the builder user the owner of these files
# Without this, (e.g. only having every user have read/write access to the files),
# makepkg will try to change the permissions of the files itself which will fail since it does not own the files/have permission
# we can't do this earlier as it will change files that are for github actions, which results in warnings in github actions logs.
chown -R runner .

# Build packages
# INPUT_MAKEPKGARGS is intentionally unquoted to allow arg splitting
# shellcheck disable=SC2086

if [ -x "/usr/bin/ccache" ]; then
  echo "Current ccache configuration:"
  ccache -p
  echo "Current ccache stats:"
  ccache -s
  echo "Reset ccache stats:"
  ccache -z
fi

if [ -n "${INPUT_ENVVARS:-}" ]; then
  sudo -H -u runner ${INPUT_ENVVARS:-} makepkg --syncdeps --noconfirm ${INPUT_MAKEPKGARGS:-}
else
  sudo -H -u runner makepkg --syncdeps --noconfirm ${INPUT_MAKEPKGARGS:-}
fi

# Get array of packages to be built
mapfile -t PKGFILES < <( sudo -u runner makepkg --packagelist )
echo "Package(s): ${PKGFILES[*]}"

# Report built package archives
i=0
for PKGFILE in "${PKGFILES[@]}"; do
	# makepkg reports absolute paths, must be relative for use by other actions
	RELPKGFILE="$(realpath --relative-base="$BASEDIR" "$PKGFILE")"
	# Caller arguments to makepkg may mean the package is not built
	if [ -f "$PKGFILE" ]; then
		echo "pkgfile$i=$RELPKGFILE" >> $GITHUB_OUTPUT
	else
		echo "Archive $RELPKGFILE not built"
	fi
	(( ++i ))
done

# Report ccache stats
if [ -x "/usr/bin/ccache" ]; then
  echo "Current ccache stats:"
  ccache -s
fi
