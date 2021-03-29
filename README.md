
# README

Install dependencies:

    $ sudo apt install libgl-dev libglu-dev freeglut3

Build:

    $ cabal new-build

Run Server:

    $ cabal new-run -- alpaca-netcode

Run Client:

    $ cabal new-run -- alpaca-netcode c

# Nix

In nix shell:

    $ nix-shell

Build:

    $ cabal new-build

Run Server:

    $ nixGL cabal new-run -- alpaca-netcode

Run Client:

    $ nixGL cabal new-run -- alpaca-netcode c


# TODO

## Easy

* [X] Make sure to simulate NetConfig options ping/jitter/drop
* [X] change tick rate argument from Int32 to Int64
* [NO] Expose only Int64 instead of Tick
* [ ] Fix all warnings
* [X] cleanup arguments for runClientWith/Server
    * Remove NetConfig + Server doesn't need NetConfig.inputLatency
* [X] refactor: Make a record for Client to return from runClientWith
* [X] Remove debug print statements
* [X] Only put current (not previous) input in the world step function's inputs
  arg.
* [ ] Review documentation
    * blocking behaviour of all IO functions / IO function arguments
* [X] Core runServerWith signature includes NetMsg, but we don't export NetMsg and
  don't really want to. I think we can just export it as an abstract type with
  Flat instance from Alpaca.NetCode.Core
* Remove `text` dependency. It is only used for EKG label output
* [X] Use defaults in runClientWith/Server and take configs in runClientWith/ServerWith.
* [ ] Add a `input -> input` prediction parameter to the server?
* [ ] Document `Tick` with basic properties of how it works

## Medium

* [ ] CI

## Hard

* [ ] An actual README
    * with a clear TODO list
    * "PRs welcome"
* [ ] Metrics.... remove EKG dependency but keep metrics
* [ ] Clean shutdown and cleanup of threads
  * Simulated network condition threads
  * search for forkIO
* [ ] Add duplication in Msg_SubmitInputs to better handle packet loss!
