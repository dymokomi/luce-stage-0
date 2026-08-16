#!/bin/sh
# Build luciaos.com into www/luciaos/out. The page is hand-written; the
# build exists to put the shared visual language and the landing frame into
# one publishable tree without keeping a second editable core.css.
set -e

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
out="$here/out"

rm -rf "$out"
mkdir -p "$out"
cp "$here/index.html" "$out/index.html"
cp "$here/style.css" "$out/style.css"
cp "$here/../shared/core.css" "$out/core.css"

cmp "$here/../shared/core.css" "$out/core.css"
echo "==> built $out"
