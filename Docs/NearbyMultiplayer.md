# Nearby NES multiplayer

Two iPhones or iPads running this build can play a two-player NES game on the same Wi-Fi network. The host runs the emulator as Player 1; the guest supplies Player 2 inputs and either generates its own video and audio from a matching imported ROM (local-ROM mode) or receives streamed video and audio. Only the host imports the ROM for streaming or writes saves; in local-ROM mode the guest uses its own identical ROM copy in a temporary directory and never writes a save. Internet play, handheld linking, other consoles, and more than two players are not supported.

## Play

1. On the host, open an NES game, open the pause menu, and choose **Nearby Multiplayer → Host Game**.
2. On the guest, open **Settings → Nearby Multiplayer**. Select the host under **Nearby Games** and enter its six-digit code.
3. Allow the Local Network permission on both devices. When Player 2 is connected, press **Start Game** on the host.
4. Choose the game's own two-player mode. Use touch controls, configured swipe gestures, or a physical controller on either device. Guest Menu contains **Mute Audio** and **Leave Game**.

Host pause pauses the game for both players. The guest menu releases guest inputs while the game continues. Save/load-state, cheat editing, and fast-forward shortcuts are unavailable during the session. Host controller assignments are restored on exit. Backgrounding or losing the connection ends the session and pauses the host; reconnect manually or continue solo.

After one successful pairing, the guest remembers the host and can rejoin without re-entering the code: hosts advertise a second rejoin service, and remembered games show a clock badge in the join list. The join screen's **Remembered Hosts** section (visible on the error screen too) lists every paired host with a Forget button — also available as a swipe or long-press on a remembered game. Forgetting a host asks for its pairing code again. If the remembered key stops working (the host app was reinstalled), the guest falls back to asking for the code.

If discovery fails, check Local Network access in iOS Settings and that both devices use the same Wi-Fi. Guest networks that isolate clients prevent nearby play. The pairing code changes for every hosted session. No accounts, remote servers, or ROM transfer are involved.

### Local-ROM mode

When the guest has imported a ROM whose SHA-256 digest matches the host's advertisement, the session switches to local-ROM mode: the guest plays with video and audio generated on its own device, without transporting PCM audio or encoded video; host input still travels over the network. The host sends its emulator state at every start/resume followed by each frame's Player 1/2 inputs; both devices run identical deterministic emulation and the guest verifies every frame against a host-computed video checksum, ending the session with an error if they diverge. If the ROMs do not match, the guest has no matching ROM, or the host has enabled cheats, the session uses streamed video and audio instead. Both devices indicate the active mode under the game title. The guest must not be running another NES game in a different window during a local-ROM session.

## Architecture

- `MultiplayerProtocol` defines bounded binary framing, protocol versioning, sequence validation, input aggregation, and session phases. Control/handshake payloads are bounded independently from PCM/H.264 and local-ROM packets (`localROM` digest, `localState` snapshot, `localFrame` per-frame inputs, `pairKey` return key).
- `MultiplayerTransport` uses Bonjour (`_deltaswipe._tcp`) and TLS-PSK over two TCP connections: one for controls/lifecycle and one for media. A random session token binds the media connection to the admitted guest. Discovery does not advertise the pairing code or the ROM digest. Hosts also advertise a second Bonjour service (`_deltaswipe-r._tcp`) whose single TLS-PSK is the persistent return key: after one code pairing, the guest stores the key (`pairKey`) and rejoins without the code. Each listener keeps exactly one PSK — registering several on one listener makes wrong-key TLS handshakes stall instead of failing fast — and unauthenticated connections time out after six seconds so wrong codes surface quickly. Authenticated connections tolerate ten seconds without control traffic; held guest inputs are still released after 500 ms. Heartbeats use common run-loop modes so scrolling and touch tracking do not suppress them. Both services are declared in `NSBonjourServices`, use a UUID instance name with title/host TXT metadata, and are matched by host identity. Joining cancels both browsers and ignores obsolete discovery callbacks.
- `MultiplayerSession` owns the session lease, Player 1/2 routing, lifecycle, and capture. Guest playback acknowledges start/resume before the host sends media. Timestamp cutoffs reject media from before a resume. In local-ROM mode it negotiates the digest during pairing, sends the host state with every start/resume epoch, and gates host frame production on the guest's acknowledgment.
- `MultiplayerLocalGame` implements the deterministic replay: the host snapshots its bridge state, applies exact frame-boundary Player 1/2 inputs through frame hooks, and checksums the video buffer; the guest replica owns a temporary ROM copy on the shared NES bridge, loads the host state, replays each frame, and verifies the checksum. The digest covers the complete ROM, including its iNES header: mapper, mirroring, trainer, and timing differences must not negotiate deterministic replay. A different dump falls back to streaming. Known core behavior: the first frame after loading a state into a machine that has already run frames repeats the previous frame's video while the machine state advances correctly, so frame 0 after each load is not checksum-verified (the guest displays the prior frame for 16 ms). Brief congestion is absorbed within bounded limits: the frame gate stops host production while sends back up (the game briefly freezes and resumes), the guest replays bursts of up to one second, and the media send budget tolerates a just-sent save state plus a burst of compressed video.
- `MultiplayerVideoEncoder` retains at most one frame through encoding/send completion. Guest PCM playback and video presentation use the same host-to-local clock, with bounded queues. Audio buffers are scheduled on a non-overlapping cursor so a late packet burst keeps its spacing instead of playing back-to-back; when the cursor trails the host schedule by more than 60 ms, single frames are skipped to shed the absorbed delay, and the eight-buffer cap re-anchors both streams. Local-ROM playback uses a 50 ms margin (Wi-Fi transit + replica execution + jitter); streaming uses 35 ms. Congestion cannot accumulate an unlimited media backlog.
- `MultiplayerInputForwarder` combines overlapping input sources. Full NES button snapshots and heartbeats keep controls current; a host-side watchdog releases guest buttons after 500 ms without an input snapshot.

Replica work is invalidated on pause/exit before draining the current native operation. Teardown releases the shared NES bridge before another session or solo game starts. Asynchronous state loads use distinct temporary files, so a newer load cannot overwrite a queued one.

The feature adds optional `VideoManager.frameHandler` and `NESEmulatorBridge.audioFrameHandler` capture callbacks plus `NESEmulatorBridge` frame-boundary hooks (`shouldRunFrameHandler`, `willRunFrameHandler`, `didRunFrameHandler`). Handlers receive owned images/data and must return promptly. They are installed/removed while the host core is paused; the frame gate also paces host emulation to the connection in local-ROM mode. `ControllerView.gameViews` is now public and read-only so remote video can also reach screens embedded in controller skins. Existing local audio and video rendering remain in place.

## Verification

Run the Foundation-only tests:

```sh
Tests/Multiplayer/run-tests.sh
```

Run the real Bonjour/TLS transport integration checks on a Mac with local networking permitted:

```sh
swiftc -O Delta/Multiplayer/MultiplayerProtocol.swift \
  Delta/Multiplayer/MultiplayerTransport.swift Tests/Multiplayer/Transport/main.swift \
  -o /tmp/deltaswipe-transport-tests
/tmp/deltaswipe-transport-tests
```

After building the workspace, run the iOS media and controller smoke tests on a booted arm64 simulator:

```sh
Tests/Multiplayer/run-ios-smoke.sh <simulator-UDID> <DerivedData>/Build/Products/Debug-iphonesimulator
```

The tests install small, separate test apps. Media checks exercise real H.264 encoding/decoding, PCM playback, presentation, mute, pause/resume, and a startup packet burst. Controller checks use the actual DeltaCore/NESDeltaCore frameworks to verify Player 2 routing, overlapping inputs, Start/Select, menu release, and disconnect cleanup. Replica checks use the real Nestopia core with a generated self-contained NES ROM to verify snapshot portability, deterministic replay of machine state and video, input sensitivity, header-sensitive ROM matching, immediate leave/rejoin, and temporary-state cleanup. Each app writes `Documents/result.txt` and exits. Display cadence in a hidden or locked simulator is not a device latency benchmark.

Run the full local-ROM session integration check across **two** booted simulators (one app per simulator; iOS suspends a backgrounded app and its network stack, which ends the session):

```sh
Tests/Multiplayer/run-ios-integration.sh <host-UDID> <guest-UDID> <DerivedData>/Build/Products/Debug-iphonesimulator
```

A protocol-level mini host plays against the real guest `MultiplayerSession` stack over real Bonjour/TLS: browse, join, pairing-code entry, ROM-digest negotiation, state load, deterministic frame replay with checksums, guest heartbeat inputs, return-key issuance, and a full host pause/resume with state resynchronization. The guest asserts locally generated audio buffers and the stored rejoin key. Both apps write pass/fail with details.

The guest keeps at most four decoded frames and eight scheduled audio buffers. A packet burst reanchors the shared playback clock and drops old buffered media. After a pause, the decoder waits for an IDR frame before resuming. Decoder callbacks are delivered outside VideoToolbox's output callback to permit safe teardown.

Build the Delta workspace for both iOS and an arm64 simulator. The checked-out melonDS assembly does not support an x86_64 simulator build; pass `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` on Apple Silicon.

Before release, verify on two physical devices with a two-player NES game (such as the user's Snow Bros copy): simultaneous controls, Start/Select, swipe autofire, independent audio mute, rotation, physical-controller reconnection, repeated sessions, network-permission denial, Wi-Fi loss, backgrounding, and host exit. Exercise local-ROM mode with the ROM imported on both devices — including host pause/resume (state resync) and streaming fallback with an unmatched or missing guest ROM — and confirm the streamed-session latency target is met on the streaming path. Compare host/guest video with high-frame-rate recording to measure input-to-display latency; the target is under 100 ms on healthy Wi-Fi. Confirm that guest storage contains no new save or leftover temporary ROM copy after a local-ROM session, and that solo play and prior controller assignments work after ending the session.

### Checked during implementation

- Foundation protocol/state/input model: 147 checks passed, including local-ROM/local-state/local-frame/pairing-key framing and the frame record roundtrip.
- Real Bonjour/TLS transport: 14 checks passed, including wrong codes, an additional guest, pairing-key issuance, and a full rejoin without the pairing code against a re-hosted listener with a different game title, distinct remembered keys for identically named games, and a 400 KB video/500 KB state burst.
- DeltaCore controller integration: 10 checks passed.
- Existing swipe engine suite: 39 checks passed.
- Real iOS media smoke: passed, including pause/resume, mute, and a packet burst.
- Real Nestopia replica smoke: 13 checks passed — snapshot portability, deterministic machine-state and video replay from a state load (including a load into a mid-run machine, matching guest resume), input sensitivity, header-sensitive ROM matching, immediate leave/rejoin, and temporary-state cleanup.
- Two-simulator local-ROM session integration: guest passed with local mode engaged (complete ROM digest matched), 452 replayed frames displayed and 456 locally generated audio buffers scheduled. Wrong-code recovery, remembered-key storage, and host pause/resume state resync passed; the host sent 457 frames across both segments (September 30 stability review).
- Full workspace and cores: arm64 simulator and iOS device builds passed with signing disabled. Existing dependency warnings remain.
- Two simulators with Snow Bros: discovery, pairing, streaming video, repeated joins, host pause/resume, restricted pause actions, guest mute, host background/exit, guest leave, and host solo recovery exercised. Guest had no ROM or save files.

Two-device physical play in both modes, audible quality on both devices, rotation/controller reconnection, permission denial, actual Wi-Fi loss, and measured latency remain manual validation items. Simulator-generated taps press and release within a single millisecond; input tracing and controller tests verify routing, but those taps do not reliably span an emulation frame.
