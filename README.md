# Alpaca NetCode

A rollback/replay client-server system for realtime multiplayer games. The API
only requires you to express your game as a pure, deterministic function.

## Advantages

* Simple code. Your game logic contains no NetCode.
* Low bandwidth. Only inputs are shared.
* Zero latency. Player's own inputs affect their game immediatly.
* UDP based. Unordered and using redundancy to mitigate packet loss.
* Lightweight server. The server does not run the game logic, it only relays and tracks user inputs.
* Cheating. Only inputs are shared which eliminates a whole class state manipulation cheats.

## Disadvantages

* Increased CPU usage. Rollback/replay means that clients must run the game step function multiple times per frame.
* Not suitable for large numbers of players. Tens of players is likey reasonable.

## Disclaimer

This is an initial release with minimal functionality and still very
experimental. Use at your own risk.

## Contributing

PRs, feadback, and feature requests welcome. See the [Roadmap
issue](https://github.com/DavidEichmann/alpaca-netcode/issues/1) for ideas. Or
ping @DavidE on the [Haskell GameDev](https://discord.gg/T7kJSq8C) discord
server.
