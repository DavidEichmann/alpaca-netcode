# TODO

## Easy

* [X] Make sure to simulate NetConfig options ping/jitter/drop
* [X] change tick rate argument from Int32 to Int64
* [NO] Expose only Int64 instead of Tick
* [X] cleanup arguments for runClientWith/Server
    * Remove NetConfig + Server doesn't need NetConfig.inputLatency
* [X] refactor: Make a record for Client to return from runClientWith
* [X] Remove debug print statements
* [X] Only put current (not previous) input in the world step function's inputs
  arg.
    * blocking behaviour of all IO functions / IO function arguments
* [X] Core runServerWith signature includes NetMsg, but we don't export NetMsg and
  don't really want to. I think we can just export it as an abstract type with
  Flat instance from Alpaca.NetCode.Core
* Remove `text` dependency. It is only used for EKG label output
* [X] Use defaults in runClientWith/Server and take configs in runClientWith/ServerWith.
* [X] Document `Tick` with basic properties of how it works
* [X] EKG dependency + Metrics
* [X] Fix all warnings
* [X] `Tick` probably shouldn't be an instance of `Semigroup`
* [X] Remove Msg_RequestAuthInput

## Medium

* [X] Test using non Core functions
* [X] Clients prune all but latest auth world (to avoid a memory leak).
* [X] Clients can stop themselves (a bit crude right now)

## Hard

* [X] Add duplication (include previously submitted inputs) in Msg_SubmitInputs
  to better handle packet loss!
  * Like the server, I probably want to have a fixed rate packet send loop
    rather than sending packets at adhoc locations in the code.
* [ ] Documentaton
  * The first documentation the user will read. Module docs? Readme? What shows
    up first on hackage?
* [ ] An actual README
  * with a clear TODO list
  * "PRs welcome"

## Future work

* [ ] Add clocksync settings to client config
* [ ] CI
* [ ] Add a `input -> input` prediction parameter to the server?
* [ ] Metrics
* [ ] Clean shutdown and cleanup of forkIO threads
  * exception handling
  * Perhaps we can leverage the `async` package
* [ ] Audit / time traveling debug
* [ ] Client Disconnect message