#! /bin/bash

# use e.g. "snake" or "rogue".
EXEC=$1

cabal new-build $EXEC &&
	(nixGL cabal new-run -- $EXEC &) &&
	sleep 2 &&
	(nixGL cabal new-run -- $EXEC c &) &&
	(nixGL cabal new-run -- $EXEC c) ||
	pkill $EXEC &&
	pkill $EXEC &&
	pkill $EXEC &&
	pkill $EXEC
