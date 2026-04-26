**WireGuard Watchdog**

Pings a peer through your WireGuard tunnel on a schedule and bounces the tunnel via `wg-quick down` / `wg-quick up` the moment the peer goes silent. Coexists cleanly with Unraid's built-in WireGuard support -- the watchdog never touches the interface directly, only invokes `wg-quick`. Configure under Tools -> User Utilities -> WireGuard Watchdog.
