#!/usr/bin/env bash
# update_git_source_package.sh: (c) 2023 Jo-Philipp Wich <jo@mein.io>
# Licensed under the terms of the Apache License, Version 2.0

MAKEFILE=$1
COMMIT=${2:-HEAD}
TOPDIR=$3

[ -n "$MAKEFILE" ] || {
	cat <<-EOT
	Usage: $0 <package name or makefile path> [revision] [topdir]

	Update an OpenWrt package Makefile with PKG_SOURCE_PROTO:=git to
	the given upstream revision (or 'HEAD' if omitted).

	The script either accepts a package name, like "netifd" or
	an absolute or relative path to a Makefile, e.g.
	"./package/utils/ucode/Makefile".

	If the revision argument is ommitted, the package is updated
	to the current HEAD of the remote Git repository.

	By default, this script tries to infer the buildroot directory
	from the package Makefile path but it may be overridden by
	passing it as 3rd argument. This is useful in situation where
	the Makefile to update does not reside within an OpenWrt buildroot.

	On success, the package Makefile is automatically modified and
	the resulting changes are committed in the currently checked
	buildroot branch using a standard commit message format.
	EOT

	exit 1
}

MAKE=$(which gmake) || MAKE=$(which make)
FIND=$(which gfind) || FIND=$(which find)

[ -x "$MAKE" ] || {
	echo "Unable to locate `make` executable" >&2
	exit 1
}

[ -x "$FIND" ] || {
	echo "Unable to locate `find` executable" >&2
	exit 1
}

[ -e "$MAKEFILE" ] || {
	MAKEFILE=$("$FIND" "${TOPDIR:-.}/package/" -type f -path "*/$MAKEFILE/Makefile" | head -n1)
}

[ -f "$MAKEFILE" ] || {
	echo "Usage: $0 <path/to/Makefile> [target commit] [path/to/buildroot/topdir]"
	exit 1
}

grep -sq BuildPackage "$MAKEFILE" || {
	echo "The file '$MAKEFILE' does not appear to be an OpenWrt package Makefile." >&2
	exit 1
}

[ -n "$TOPDIR" ] || {
	TOPDIR=$(cd "$(dirname "${MAKEFILE%/*}")"; pwd)

	while [ "$TOPDIR" != "/" ]; do
		TOPDIR=$(dirname "$TOPDIR")
		[ -f "$TOPDIR/rules.mk" ] && break
	done

	[ -f "$TOPDIR/rules.mk" ] || {
		echo "Unable to determine buildroot directory." >&2
		exit 1
	}
}

export TOPDIR
export PATH="$TOPDIR/staging_dir/host/bin:$PATH"

eval $(
	"$MAKE" --no-print-directory -C "$(dirname "$MAKEFILE")" \
		var.PKG_NAME \
		var.PKG_RELEASE \
		var.PKG_SOURCE_PROTO \
		var.PKG_SOURCE_URL \
		var.PKG_SOURCE_DATE \
		var.PKG_SOURCE_VERSION \
		var.PKG_MIRROR_HASH
)

case "$PKG_SOURCE_PROTO:$PKG_SOURCE_URL" in
	git:http://*|git:https://*|git:git://*|git:file:*)
		:
	;;
	*)
		echo "Unsupported combination of source protocol ('$PKG_SOURCE_PROTO') and url ('$PKG_SOURCE_URL')." >&2
		exit 1
	;;
esac

TEMP_GIT_DIR=

for signal in INT TERM EXIT; do
	trap '
		[ -d "$TEMP_GIT_DIR" ] && rm -rf "$TEMP_GIT_DIR";
		git -C "$(dirname "$MAKEFILE")" checkout --quiet "$(basename "$MAKEFILE")"
	' $signal
done

TEMP_GIT_DIR=$(mktemp -d) || {
	echo "Unable to create temporary Git directory." >&2
	exit 1
}

git clone --bare "$PKG_SOURCE_URL" "$TEMP_GIT_DIR" || {
	echo "Unable to clone Git repository '$PKG_SOURCE_URL'." >&2
	exit 1
}

GIT_LOG="$(git -C "$TEMP_GIT_DIR" log \
	--reverse --no-merges \
	--abbrev=12 \
	--format="%h %s" \
	"$PKG_SOURCE_VERSION..$COMMIT" \
)" || {
	echo "Unable to determine changes from commit '$PKG_SOURCE_VERSION' to '$COMMIT'." >&2
	exit 1
}

GIT_DATE_COMMIT=$(git -C "$TEMP_GIT_DIR" log \
	-1 --format='%cd %H' \
	--date='format:%Y-%m-%d' \
	"$COMMIT" \
) || {
	echo "Unable to determine target commit ID and date." >&2
	exit 1
}

GIT_FIXES="$(
	IFS=$', \t\n'
	for issue in $(
		git -C "$TEMP_GIT_DIR" log \
			--format="%b" \
			"$PKG_SOURCE_VERSION..$COMMIT" \
		| sed -rne 's%^Fixes:(([ ,]*([[:alnum:]_]*#[0-9]+|https?://[^[:space:]]+))+)$%\1%p'
	); do
		case "$issue" in
		http://*|https://*)
			echo "$issue"
		;;
		GH#[0-9]*|openwrt#[0-9]*)
			echo "https://github.com/openwrt/openwrt/issues/${issue#*#}"
		;;
		FS#[0-9]*)
			echo "https://bugs.openwrt.org/?task_id=${issue#FS#}"
		;;
		[a-zA-Z0-9_]*#[0-9]*)
			echo "https://github.com/openwrt/${issue%#*}/issues/${issue#*#}"
		;;
		'#'[0-9]*)
			case "$PKG_SOURCE_URL" in
			*://github.com/*)
				echo "${PKG_SOURCE_URL%/}/issues/${issue#\#}"
			;;
			*://git.openwrt.org/project/*)
				project=${PKG_SOURCE_URL#*://git.openwrt.org/project/}
				project=${project%.git}
				echo "https://github.com/openwrt/${project}/issues/${issue#\#}"
			;;
			esac
		;;
		esac
	done \
	| sort --version-sort \
	| uniq \
	| sed -e 's#^#Fixes: #'
)"

sed -i -r \
	-e "/PKG_SOURCE_VERSION/s#\<$PKG_SOURCE_VERSION\>#${GIT_DATE_COMMIT#* }#" \
	-e "/PKG_SOURCE_DATE/s#\<$PKG_SOURCE_DATE\>#${GIT_DATE_COMMIT% *}#" \
	"$MAKEFILE"

if [ -n "$PKG_RELEASE" ] && [ "$PKG_RELEASE" != "1" ]; then
	sed -i -r \
		-e "/PKG_RELEASE/s#\<$PKG_RELEASE\>#1#" \
		"$MAKEFILE"
fi

eval $(
	"$MAKE" --no-print-directory -C "$(dirname "$MAKEFILE")" \
		var.PKG_SOURCE
)

"$MAKE" -C "$(dirname "$MAKEFILE")" download CONFIG_SRC_TREE_OVERRIDE= || {
	echo "Unable to download and pack updated Git sources." >&2
	exit 1
}

DL_HASH=$(sha256sum "$TOPDIR/dl/$PKG_SOURCE") || {
	echo "Unable to determine archive checksum." >&2
	exit 1
}

sed -i -r \
	-e "/PKG_MIRROR_HASH/s#\<$PKG_MIRROR_HASH\>#${DL_HASH%% *}#" \
	"$MAKEFILE"

git -C "$(dirname "$MAKEFILE")" commit \
	--signoff --no-edit \
	--message "$PKG_NAME: update to Git $COMMIT (${GIT_DATE_COMMIT% *})" \
	--message "$GIT_LOG" \
	${GIT_FIXES:+--message "$GIT_FIXES"} \
	"$(basename "$MAKEFILE")"

"$MAKE" --no-print-directory -C "$(dirname "$MAKEFILE")" check || {
	echo "WARNING: Package check failed for updated Makefile!"
	exit 1
}
