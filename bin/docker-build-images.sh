#!/bin/sh
# shellcheck shell=dash

#
# Builds images for each Dockerfile found recursively in the given directory.
# Resolves image dependencies for images in the same organization.
# Tags images based on the directory structure and git branch names.
#
# Usage: ./docker-build-images.sh [Dockerfile|directory] [...]
#
# The parent directory basename is used as the user/organization name.
# The current directory basename is used as the repository name.
# The branch is used as the version, with "master" being tagged as "latest".
# e.g.: parentdir/currentdir:latest
#
# If DOCKER_ORG is defined, it is used as the user/organization name.
# If DOCKER_HUB is defined, it is prefixed to the user/organization name.
# e.g.: $DOCKER_HUB/$DOCKER_ORG/repository:latest
#
# Copyright 2015, Sebastian Tschan
# https://blueimp.net
#
# Licensed under the MIT license:
# http://www.opensource.org/licenses/MIT
#

# Normalizes according to docker hub organization/image naming conventions:
normalize() {
	echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]//g'
}

# Build and tag the image based on the git branches in the current directory:
build_versions() {
	local image="$1"
	if [ ! -d '.git' ]; then
		# Not a git repository, so simply build a "latest" image version:
		docker build -t "$image" .
		return $?
	fi
	local current_branch
	current_branch=$(git rev-parse --abbrev-ref HEAD)
	# Iterate over all branches:
	local branches
	branches=$(git for-each-ref --format='%(refname:short)' refs/heads/)
	local branch
	for branch in $branches; do
		git checkout "$branch"
		# Tag master as "latest":
		if [ "$branch" = 'master' ]; then
			branch='latest'
		fi
		# Build and tag the image with the branch name:
		docker build -t "$image:$branch" .
	done
	git checkout "$current_branch"
}

# Builds an image for each git branch of the given Dockerfile directory:
build() {
	local cwd="$PWD"
	local file
	file="$(basename "$1")"
	local dir
	dir="$(dirname "$1")"
	cd "$dir" || return 1
	local organization="$DOCKER_ORG"
	if [ -z "$organization" ]; then
		# Use the parent folder for the organization/user name:
		organization="$(cd .. && normalize "$(basename "$PWD")")"
	fi
	if [ ! -z "$DOCKER_HUB" ]; then
		organization="$DOCKER_HUB/$organization"
	fi
	local image
	# Use the current folder for the image name:
	image="$organization/$(normalize "$(basename "$PWD")")"
	# Check if the image depends on another image of the same organization:
	local from
	from=$(grep "^FROM $organization/" "$file" | awk '{print $2}')
	# If it does, only build if the image is already available:
	if [ -z "$from" ] || docker inspect "$from" > /dev/null 2>&1; then
		build_versions "$image"
	else
		echo "$image requires $from ..." >&2 && false
	fi
	local status=$?
	cd "$cwd" || return 1
	return $status
}

# Builds and tags images for each Dockerfile in the arguments list:
build_images() {
	# Set the maximum number of calls on the first run:
	if [ "$MAX_CALLS" = 0 ]; then
		# Worst case scenario needs n*(n+1)/2 calls for dependency resolution,
		# which is the sum of all natural numbers (1+2+3+4+...n).
		# n is the number of arguments (=Dockerfiles) provided:
		MAX_CALLS=$(($#*($#+1)/2))
	fi
	CALLS=$((CALLS+1))
	if [ $CALLS -gt $MAX_CALLS ]; then
		echo 'Could not resolve image dependencies.' >&2
		return 1
	fi
	local file
	for file; do
		# Shift the arguments list to remove the current Dockerfile:
		shift
		# Baisc check if the file is a valid Dockerfile:
		if ! grep '^FROM ' "$file"; then
			echo "Invalid Dockerfile: $file" >&2
			continue
		fi
		if ! build "$file"; then
			# The current build requires another image as dependency,
			# so we add it to the end of the build list and start over:
			build_images "$@" "$file"
			return $?
		fi
	done
}

MAX_CALLS=0
CALLS=0
NEWLINE='
'

# Parses the arguments, finds Dockerfiles and starts the builds:
init() {
	local args=''
	local arg
	for arg; do
		if [ -d "$arg" ]; then
			# Search for Dockerfiles and add them to the list:
			args="$args$NEWLINE$(find "$arg" -name Dockerfile)"
		else
			args="$args$NEWLINE$arg"
		fi
	done
	# Set the list as arguments, splitting only at newlines:
	IFS="$NEWLINE";
	# shellcheck disable=SC2086
	set -- $args;
	unset IFS
	build_images "$@"
}

init "${@:-.}"