#!/usr/bin/env bash

git_author="$(git config user.name)"
git_email="$(git config user.email)"
gpg_keyid=""

base_url="https://downloads.openwrt.org/releases"

[ -f "./feeds.conf.default" ] || {
	echo "Please execute as ./${0##*/}" >&2
	exit 1
}

usage() {
	{
		echo ""
		echo "Usage: $0 [-i] [-a <Git author>] [-e <Git email>] \\"
		echo "          [-k <GPG key id>] [-p <GPG passphrase file>] \\"
		echo "          [-u <Download base url>] -v <version>"
		echo ""
		echo "-i"
		echo "Exit successfully if tag already exists"
		echo ""
		echo "-a Git author [$git_author]"
		echo "Override the author name used for automated Git commits"
		echo ""
		echo "-e Git email [$git_email]"
		echo "Override the email used for automated Git commits"
		echo ""
		echo "-k GPG key id [${gpg_keyid:-none}]"
		echo "Enable GPG signing of tags with given GPG key id"
		echo ""
		echo "-p GPG passphrase file [none]"
		echo "Use the passphrase stored in the given file for signing"
		echo ""
		echo "-u Download base url [$base_url]"
		echo "Use the given URL as base for download repositories"
		echo ""
		exit 1
	} >&2
}

while getopts "a:e:ik:p:u:v:" opt; do
	case "$opt" in
		a) git_author="$OPTARG" ;;
		e) git_email="$OPTARG" ;;
		i) ignore_existing=1 ;;
		k) gpg_keyid="${OPTARG#0x}" ;;
		p) gpg_passfile="${OPTARG}" ;;
		u) base_url="${OPTARG%/}" ;;
		v)
			case "$OPTARG" in
				[0-9]*.[0-9]*.[0-9]*)
					version="$OPTARG"
					basever="$(echo "$version" | cut -d. -f1-2)"
				;;
				*)
					echo "Unexpected version format: $OPTARG" >&2
					exit 1
				;;
			esac
		;;
		\?)
			echo "Unexpected option: -$OPTARG" >&2
			usage
		;;
		:)
			echo "Missing argument for option: -$OPTARG" >&2
			usage
		;;
	esac
done

[ -n "$version" ] || usage

if git rev-parse "v${version}^{tag}" >/dev/null 2>/dev/null; then
	if [ -z "$ignore_existing" ]; then
		echo "Tag v${version} already exists!" >&2
		exit 1
	fi

	exit 0
fi

revnum="$(./scripts/getver.sh)"
epoch="$(./scripts/get_source_date_epoch.sh)"

branch="$(git symbolic-ref -q HEAD)"
distro="OpenWrt"

case "$branch" in
	*-$basever) : ;;
	*)
		echo "Expecting current branch name to end in \"-$basever\"," \
		     "but it is \"${branch#refs/heads/}\" - aborting."

		exit 1
	;;
esac

case "$branch" in
	*/lede-*) distro="LEDE" ;;
	*/openwrt-*) distro="OpenWrt" ;;
esac

export GIT_AUTHOR_NAME="$git_author"
export GIT_AUTHOR_EMAIL="$git_email"
export GIT_COMMITTER_NAME="$git_author"
export GIT_COMMITTER_EMAIL="$git_email"

while read type name url; do
	case "$type" in
		src-git|\
		src-git-full)
			case "$url" in
				*^*)  sha1="${url##*^}" ;;
				*\;*) sha1="$(git ls-remote "${url%;*}" "${url##*;}")" ;;
				*)    sha1="$(git ls-remote "$url" "master")" ;;
			esac
			echo "$type $name ${url%[;^]*}${sha1:+^${sha1:0:40}}"
		;;
		src-svn)
			case "$url" in
				*\;*) rev="${url##*;}" ;;
				*)    rev="$(svn log -l 1 "$url" | sed -ne '2s/ .*$//p')" ;;
			esac
			echo "$type $name ${url%;*}${rev:+;$rev}"
		;;
		src-*)
			echo "$type $name $url"
		;;
	esac
done < feeds.conf.default > feeds.conf.tagged && \
	mv feeds.conf.tagged feeds.conf.default

sed -e 's!\(VERSION_NUMBER:=\$(if .*\),[^,]*)!\1,'"$version"')!g' \
    -e 's!\(VERSION_CODE:=\$(if .*\),[^,]*)!\1,'"$revnum"')!g' \
    -e 's!\(VERSION_REPO:=\$(if .*\),[^,]*)!\1,'"$base_url/$version"')!g' \
	include/version.mk > include/version.tagged && \
		mv include/version.tagged include/version.mk

sed -e 's!\(http\|https\)://downloads.\(openwrt\|lede-project\).org/[^"]*!'"$base_url/$version"'!g' \
    -e '/config VERSION_CODE_FILENAMES/ { :next; n; s!default y!default n!; t end; b next }; :end' \
	package/base-files/image-config.in > package/base-files/image-config.tagged && \
		mv package/base-files/image-config.tagged package/base-files/image-config.in

echo "$revnum" > version && git add version
echo "$epoch" > version.date && git add version.date

git commit -sm "$distro v$version: adjust config defaults" \
	feeds.conf.default \
	include/version.mk \
	package/base-files/image-config.in \
	version version.date


if [ -n "$gpg_keyid" -a -n "$gpg_passfile" ]; then
	gpg_script="$(tempfile)"

	cat <<-EOT > "$gpg_script"
		#!/usr/bin/env bash
		exec $(which gpg) --batch --passphrase-file $gpg_passfile "\$@"
	EOT

	chmod 0700 "$gpg_script"
fi

git ${gpg_script:+-c "gpg.program=$gpg_script"} tag \
	-a "v$version" \
	-m "$distro v$version Release" \
	${gpg_keyid:+-s -u "$gpg_keyid"}

[ -n "$gpg_script" ] && rm -f "$gpg_script"

git revert --no-edit HEAD
git commit --amend -sm "$distro v$version: revert to branch defaults"

git --no-pager show "v$version"

cat <<EOT
# Push the branch and tag with:
git push origin "${branch#refs/heads/}"
git push --follow-tags origin "refs/tags/v$version:refs/tags/v$version"
EOT
