#!/bin/sh
pkgrel=0
muon_base_args="-Dbuildtype=release \
-Dprefix=/usr \
-Dlibexecdir=lib \
-Ddefault_library=shared \
-Dwarning_level=0 \
-Dwerror=false"

set -e

export HOST_ARCH=$(uname -m)

if uname -o | grep GNU >/dev/null; then
	export HOST_TRIPLE="$HOST_ARCH-unknown-linux-gnu"
else
	export HOST_TRIPLE="$HOST_ARCH-unknown-linux-musl"
fi

command -V bad 2>/dev/null || bad() {
	shift
	"$@"
}

bad --gmake command -V gmake 2> /dev/null || gmake() {
	make "$@"
}

usage() {
	echo "usage: $(basename $0) [fbp]"
	echo "usage: f: fetch"
	echo "usage: b: build"
	echo "usage: p: package"
	echo "version: 0.1.1"
	exit 1
}

fatal() {
	echo "ERROR: $@"
	usage
	exit 1
}

warn() {
	echo "WARNING: $@"
}

to_run=
while [ ! -z "$1" ]; do
	case "$1" in
		--with-cross=*)
			ARCH=$(echo "$1" | cut -d'=' -f2)
			[ -z "$ARCH" ] && fatal '--with-cross=<arch> requires an argument'
			echo "INFO: cross compiling for $ARCH"
			WITH_CROSS="$ARCH"
			;;
		--with-cross)
			fatal '--with-cross=<arch> requires an argument'
			;;
		--with-cross-dir=*)
			WITH_CROSS_DIR=$(echo "$1" | cut -d'=' -f2)
			[ -z "$WITH_CROSS_DIR" ] && fatal '--with-cross-dir=<sysroot> requires an argument'
			[ -d "$WITH_CROSS_DIR" ] 2>/dev/null || warn "$WITH_CROSS_DIR does not exist"
			echo "INFO: using toolchain libraries from $WITH_CROSS_DIR"
			;;
		--with-cross-dir)
			fatal '--with-cross-dir=<sysroot> requires an argument'
			;;
		--for-cross)
			echo 'INFO: for cross'
			FOR_CROSS=1
			;;
		--for-cross-dir=*)
			FOR_CROSS_DIR_SET=1
			FOR_CROSS_DIR=$(echo "$1" | cut -d'=' -f2)
			#[ -z "$FOR_CROSS_DIR" ] && fatal '--for-cross-dir=<sysroot> requires an argument'
			echo "INFO: packaging for prefix $FOR_CROSS_DIR"
			;;
		--for-cross-dir)
			fatal '--for-cross-dir=<sysroot> requires an argument'
			;;
		fbp)
			to_run="f b p"
			;;
		fb)
			to_run="f b"
			;;
		f)
			to_run="f"
			;;
		bp)
			to_run="b p"
			;;
		b)
			to_run="b"
			;;
		p)
			to_run="p"
			;;
		x)
			to_run="x"
			;;
		*)
			fatal "invalid argument $1"
			;;
	esac
	shift
done

[ -z "$WITH_CROSS_DIR" ] && WITH_CROSS_DIR=/usr/$ARCH-linux-musl
[ -z "$FOR_CROSS_DIR_SET" ] && FOR_CROSS_DIR=/usr/$ARCH-linux-musl

if [ -z "$ARCH" ]; then
	export ARCH=$HOST_ARCH
fi

if [ ! -z "$FOR_CROSS" ]; then
	cross=-$ARCH
fi
export TRIPLE="$ARCH-unknown-linux-musl"
[ -z "$CC" ] && export CC=cc
[ -z "$CXX" ] && export CXX=c++
export AR=ar
export RANLIB=ranlib
export CROSS_EXTRA_LDFLAGS="--target=$TRIPLE --sysroot=$WITH_CROSS_DIR"
export CFLAGS="-O3"
export CROSS_EXTRA_CFLAGS="--target=$TRIPLE --sysroot=$WITH_CROSS_DIR"
export CXXFLAGS=$CFLAGS
export CROSS_EXTRA_CXXFLAGS="$CROSS_EXTRA_CFLAGS -nostdinc++ -isystem $WITH_CROSS_DIR/include/c++/v1/"

auto_cross() {
	if [ -z "$FOR_CROSS" ]; then
		PREFIX=/usr
	else
		PREFIX=$FOR_CROSS_DIR
	fi
	[ -z "$WITH_CROSS" ] && return
	export CFLAGS="$CFLAGS $CROSS_EXTRA_CFLAGS"
	export CXXFLAGS="$CFLAGS $CROSS_EXTRA_CXXFLAGS"
	export LDFLAGS="$CROSS_EXTRA_LDFLAGS"
}

export JOBS=$(nproc)

[ -f build.sh ] || fatal 'build.sh not found'

. ./build.sh

if command -V iglu 2>/dev/null; then
	[ -z "$mkdeps" ] || iglu has $mkdeps \
		|| warn 'missing make dependancies'
	[ -z "$deps" ] || iglu has $deps \
		|| warn 'missing runtime dependancies'
fi

srcdir="$(pwd)/src"
outdir="$(pwd)/out"
pkgdir="$(pwd)/out/$pkgname$cross.$pkgver"

[ -d "$pkgdir" ] || warn "package already built. Pass f b or p."

_genmeta() {
	echo "[pkg]"
	echo "pkgname=$pkgname"
	echo "pkgver=$pkgver"
	echo "deps=$deps"
	echo ""
	echo "[license]"
	license
	echo ""
	echo "[backup]"
	backup
	echo ""
	echo "[fs]"

	cd "$pkgdir"
	find *
	cd "$srcdir"
}

_f() {
	rm -rf "$pkgdir"
	rm -rf "$srcdir"
	mkdir -p "$srcdir"
	cd "$srcdir"
	fetch
	cd "$srcdir"
	:> .fetched
}

_b() {
	rm -rf "$pkgdir"
	cd "$srcdir"
	[ -f .fetched ] || fatal 'must fetch before building'
	MAKEFLAGS=-j"$JOBS" build
	cd "$srcdir"
	:> .built
}

_x() {
	cd "$srcdir"
	all_deps="$deps:$rdeps"
	IFS=: set -- $all_deps
	t_deps=$(printf '%s\n' $@ | grep -v '>=')
	if [ ! -z "$t_deps" ]
	then
		n_deps=$(printf '%s\n' $@ | grep -v '>=' | awk '{printf $0">=0 "}')
	fi
	y_deps=$(printf '%s\n' $@ | grep '>=' || : )
	cd "$outdir"
	if [ -z "$desc" ]
	then
		desc="TODO"
	fi
	set -x
	xbps-create -A $ARCH-musl -n $pkgname-$pkgver\_$pkgrel -s "$desc" -D "$n_deps $y_deps" "$pkgdir"
	set +x
}

_p() {
	rm -rf "$pkgdir"
	cd "$srcdir"
	[ -f .built ] || fatal 'must build before packaging'
	mkdir -p "$pkgdir"
	package
	install -d "$pkgdir/usr/share/iglupkg/"
	cd "$srcdir"
	_genmeta > "$pkgdir/usr/share/iglupkg/$pkgname$cross"
	if command -V xbps-create
	then
		_x
	fi
}

if [ -z "$to_run" ]; then
	[ -f "$srcdir/.fetched" ] || _f
	[ -f "$srcdir/.built" ] || _b
	[ -d "$pkgdir" ] || _p
else
	set -- $to_run

	while [ ! -z "$1" ]; do
		_"$1"
		shift
	done
fi
