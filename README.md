# TODO Documentaton

* [ ] Move everything execpt the simple api into Advanced module
* [ ] Cabal package description etc.
  * Clear summary + elevator pitch
  * Pointing to Alpaca.NetCode for more documentation
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