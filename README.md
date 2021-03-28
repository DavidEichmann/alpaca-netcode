
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

* Propperly support deterministic simulation
    * [ ] Guaranteed delivery of inputs! We need total info to keep clients in sync.
        * see `Msg_RequestAuthInput`
    * [X] Clients write into the auth_worlds TVar when they have complete Inputs :-)
    * [ ] We need to avoid long pauses when receiving old inputs (perhaps introduce
      more threading?)
        * You'll probably need to cache the most recent predicted worlds or
          something like that.

* Investigate high CPU usage after a few mins of playing snake
* nix build / dev env
    * use nixGL to run:
        nixGL cabal new-run -- alpaca-netcode-core
* Handle dropped packets (redundancy)
    * Which messages need redundancy?
        * Submit inputs
        * Auth inputs
            * we could aim to make this reliable (but out of order) at least
              since the last received world snapshot. We really don't want to
              miss out auth inputs as that means miss predictions.
* Do we need guaranteed delivery?
    * for inputs? Maybe only if we assume deterministic step function and never
      send auth. world updates.
* Rate limit sending world state
* reduce rollback by saving world states of previous run. We can safely reuse as
  long as inputs used to simulate haven't changed
