#!/bin/sh
# Clone the upstream MiSTer core at the pinned commit and apply this port's
# patch. Run once after a fresh checkout.
set -e
cd "$(dirname "$0")/.."
COMMIT=$(cat patches/UPSTREAM_COMMIT)

if [ ! -d upstream ]; then
	git clone https://github.com/MiSTer-devel/NGPC_MiSTer.git upstream
fi

cd upstream
git fetch --all
git checkout "$COMMIT"
git apply --check ../patches/ngpc-upstream-patches.diff
git apply ../patches/ngpc-upstream-patches.diff
echo "upstream at $COMMIT, patch applied"
