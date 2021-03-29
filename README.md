
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

## Easy Stuff

* [X] Make sure to simulate NetConfig options ping/jitter/drop
* [ ] change tick rate argument from Int32 to Int64
* [ ] Expose only Int64 instead of Tick
* [ ] Metrics.... remove EKG dependency but keep metrics
* [ ] Fix all warnings
* [ ] cleanup arguments for runClient/Server
    * Remove NetConfig + Server doesn't need NetConfig.inputLatency
* [ ] refactor: Make a record for Client to return from runClient
* [ ] Remove debug print statements
* [ ] Only put current (not previous) input in the world step function's inputs
  arg.
* [ ] Review documentation
    * blocking behaviour of all IO functions / IO function arguments
* [ ] Core runServer signature includes NetMsg, but we don't export NetMsg and
  don't really want to. I think we can just export it as an abstract type with
  Flat instance from Alpaca.NetCode.Core

## Hard Stuff

* [ ] Clean shutdown and cleanup of threads
  * Simulated network condition threads
  * search for forkIO
* [ ] Add duplication in Msg_SubmitInputs to better handle packet loss!
