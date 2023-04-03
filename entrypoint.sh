#!/bin/bash
set -euo pipefail

FILE="$(basename "$0")"

# Use all available threads to build a package
sed -i 's/#MAKEFLAGS="-j2"/MAKEFLAGS="-j$(nproc) -l$(nproc)"/g' /etc/makepkg.conf

# Install base-devel + sccache
pacman -Syu --noconfirm --needed base-devel sccache

# Configure sccache
export SCCACHE_CACHE_SIZE="200MB"
export SCCACHE_DIR="/home/builder/.sccache"

# Makepkg does not allow running as root
# Create a new user `builder`
# `builder` needs to have a home directory because some PKGBUILDs will try to
# write to it (e.g. for cache)
useradd builder -m
# When installing dependencies, makepkg will use sudo
# Give user `builder` passwordless sudo access
echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Give all users (particularly builder) full access to these files
chmod -R a+rw .

BASEDIR="$PWD"
cd "${INPUT_PKGDIR:-.}"

# Make the builder user the owner of these files
# Without this, (e.g. only having every user have read/write access to the files),
# makepkg will try to change the permissions of the files itself which will fail since it does not own the files/have permission
# we can't do this earlier as it will change files that are for github actions, which results in warnings in github actions logs.
chown -R builder .

# Build packages
# INPUT_MAKEPKGARGS is intentionally unquoted to allow arg splitting
# shellcheck disable=SC2086

if [ -n "${INPUT_ENVVARS:-}" ]; then
  sudo -H -u builder ${INPUT_ENVVARS:-} makepkg --syncdeps --noconfirm ${INPUT_MAKEPKGARGS:-}
else
  sudo -H -u builder makepkg --syncdeps --noconfirm ${INPUT_MAKEPKGARGS:-}
fi

# Get array of packages to be built
mapfile -t PKGFILES < <( sudo -u builder makepkg --packagelist )
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

# Show sccache hits
if [ -x "/usr/bin/sccache" ]; then
    echo
    echo "sccache stats:"
    sccache --show-stats
fi
