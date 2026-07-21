# BookShare

**Peer-to-peer ebook sharing between KOReader devices over Wi-Fi.**

BookShare lets two people running KOReader (jailbroken Kindles, Kobos, or any KOReader device) share ebooks directly with each other. Each person picks which folders on their own device to share, exchanges a friend code, and can then browse and download from the other person's library. No server, no cloud, no account. Just two devices talking on the same network.

> **Roadmap note:** BookShare currently works on the same Wi-Fi network only. Support for sharing over external networks / the internet is planned. See [Roadmap](#roadmap).

## Features

- **Folder-level sharing.** You decide exactly which folders are visible. Nothing outside them is reachable, by design (books are served by opaque ids, never by path, so there is no path traversal surface).
- **Friend codes.** Each device generates a random 16-character code (e.g. `K7Q2-M9XP-4RTA-BC3D`). The code is both the identity and the access key. No one on your network can browse your library without it.
- **One-tap mutual pairing.** When you add a friend's code, BookShare can send them a friend request over the LAN. They get a popup on their device and can add you back with a single tap, no typing.
- **Automatic discovery.** Devices find each other via UDP broadcast. If your router blocks broadcast, manual IP entry works as a fallback (it accepts `ip`, `ip:port`, or a full URL).
- **Non-blocking downloads with progress.** Transfers are pumped in chunks through KOReader's scheduler, so the UI stays responsive and you see a progress percentage. Tolerant of Kindle Wi-Fi power-save naps.
- **Kindle firewall handling.** On Kindle, the plugin opens the needed iptables ports when sharing starts and closes them when it stops. No manual setup.
- **Open downloaded books immediately.** When a download finishes you can open it right away, or find it later in a configurable download folder (default: `From Friends`).

## How it works

Turning on "Share my books" starts two tiny services on your device:

1. An HTTP server (default port 8135) with four endpoints: `/ping` (identity), `/list` (your shared books), `/get?id=N` (download a book), and `/pair` (incoming friend requests). Everything except `/ping` requires your friend code as a bearer token.
2. A UDP discovery responder (port 8134) so friends on the same network can find your device without knowing its IP.

Browsing a friend's library scans the LAN, authenticates with the code they gave you, lists their shared books, and streams your picks to your download folder. Connection attempts retry automatically because e-ink devices are notorious for dropping the first packets of a fresh connection while their Wi-Fi radio is in power-save mode.

## Install

### Jailbroken Kindle (or any device with KOReader)

1. Copy the `bookshare.koplugin` folder into KOReader's plugins directory. On Kindle over USB that is `/mnt/us/koreader/plugins/bookshare.koplugin/`.
2. Restart KOReader.
3. Find **Book Share** in the Tools menu.

Install on both devices.

### Desktop (for development)

Put `bookshare.koplugin` in `~/.config/koreader/plugins/` (Linux) and restart KOReader. Two instances with separate `HOME` values on one machine can pair with each other for testing.

## Usage

### One-time setup, on each device

1. **Tools → Book Share → Sharing → Shared folders**: add the folder(s) you want to expose. Subfolders are included, three levels deep.
2. **Tools → Book Share → My friend code**: this is what you give your friend.

### Pairing

On one device: **Friends → Add friend**, enter their name and the code they gave you. BookShare then offers to send a friend request. If their sharing is on, a popup appears on their device and they can add you back with one tap. Done, you are mutually paired.

If they were not sharing at the time, you can resend later: **Friends → Manage friends**, tap a friend to send a request (hold a friend to remove them).

### Swapping books

1. The person sharing turns on **Share my books** (Wi-Fi required; KOReader's "keep Wi-Fi on" network setting helps).
2. The person browsing picks **Browse a friend's library**, taps books, watches the progress ticker, reads.
3. Turn sharing off when done.

## Troubleshooting

- **"Couldn't find them automatically."** Some routers and most guest networks block UDP broadcast between clients. Use the manual IP entry (the sharer's address is shown on their screen when sharing starts). Any format works: plain IP, `ip:port`, or a pasted URL.
- **Connection timeouts.** Check that both devices are on the same subnet (mesh nodes, extenders, and separate 2.4/5 GHz SSIDs can split devices onto different networks) and that your router does not have AP/client isolation enabled.
- **Quick reachability test.** With sharing on, visit `http://KINDLE_IP:8135/ping` from a phone or laptop browser on the same network. A small JSON blob means the server is reachable; a timeout means the network is blocking it.
- **Transfers stall.** E-ink devices drop Wi-Fi aggressively in sleep. Keep the sharing device awake during transfers, or raise its sleep timeout.
- **Logs.** Look for lines tagged `BookShare:` in `koreader/crash.log`.

## Security model (read this)

The friend code is a bearer token sent over plain HTTP on your local network. That is an appropriate level of security for lending books to a friend on your home Wi-Fi, and not more than that. Anyone who has your code can browse and download from your shared folders while sharing is on. If a code leaks, regenerate it from **My friend code → Regenerate** (friends will need the new one). Turn sharing off when you are not using it.

## Architecture

| File | Purpose |
|---|---|
| `_meta.lua` | Plugin metadata for KOReader |
| `main.lua` | UI, settings, menu tree, pairing and download flows |
| `httpserver.lua` | Non-blocking HTTP server (`/ping`, `/list`, `/get`, `/pair`) |
| `httpclient.lua` | Client side: list, pair, and path handling |
| `asyncdownload.lua` | Chunked non-blocking download pump with progress |
| `discovery.lua` | UDP broadcast discovery (responder + scanner) |
| `friendcode.lua` | Code generation and normalization (Crockford base32, `/dev/urandom`) |
| `jsonutil.lua` | JSON via bundled rapidjson/dkjson, with a built-in fallback |

Both the HTTP server and discovery responder are module-level singletons polled through `UIManager:scheduleIn`, so they survive KOReader recreating plugin instances when switching between the file manager and the reader.

## Roadmap

- [ ] **Internet / external network support.** Sharing with friends who are not on your Wi-Fi. The likely path is a lightweight rendezvous/relay option plus first-class support for overlay networks (BookShare already works over Tailscale between two jailbroken Kindles today via manual IP entry, since a tailnet looks like a LAN). Friend codes and the wire protocol were designed so the transport can change without re-pairing.
- [ ] Async transfers on the server side (the sharing device's UI currently pauses while streaming a file out)
- [ ] Cover thumbnails and richer metadata in the library listing
- [ ] Per-friend folder permissions (share one folder with one friend, everything with another)
- [ ] Transfer cancellation and a download queue

## Requirements

- KOReader (uses only bundled libraries: LuaSocket, lfs, and rapidjson/dkjson with a built-in JSON fallback)
- Two devices on the same Wi-Fi network (for now, see Roadmap)

## License

MIT
