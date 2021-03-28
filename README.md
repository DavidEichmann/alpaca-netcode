
# README

Install dependencies:

    $ sudo apt install libgl-dev libglu-dev freeglut3

Build:

    $ cabal new-build

Run Server:

    $ cabal new-run -- alpaca-netcode-core

Run Client:

    $ cabal new-run -- alpaca-netcode-core c

# Nix

In nix shell:

    $ nix-shell

Build:

    $ cabal new-build

Run Server:

    $ nixGL cabal new-run -- alpaca-netcode-core

Run Client:

    $ nixGL cabal new-run -- alpaca-netcode-core c


# TODO

* [X] Make sure to simulate NetConfig options ping/jitter/drop
* [ ] Clean shutdown and cleanup of threads
  * Simulated network condition threads
  * search for forkIO
* [ ] Add duplication in Msg_SubmitInputs to better handle packet loss!
