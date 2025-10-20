Progress: I added a new todo for drafting the integrations blueprint and started it. Next, here’s the complete blueprint you can copy into your new project to guide the fork and helper work.
Here’s a focused, implementation-ready blueprint you can drop into your new project repo to guide the fork and helper/UI work. It centers on JACK control, Pulse/PipeWire disablement, Icecast/Liquidsoap/Stereo Tool orchestration, AES67 abstraction, precise Polkit gating, and clean integration with the offline installer—while keeping changes additive to Rivendell.

## Objectives

- Centralize control of JACK (start/stop, profiles, graph/patchbay) from within Rivendell (via a new module or a tightly integrated companion).
- Eliminate Pulse/PipeWire to prevent non-broadcast audio from leaking.
- Provide reliable start/stop and config management for Icecast, Liquidsoap, and Stereo Tool—with pre-flight checks, backups, and rollback.
- Offer a pluggable AES67 control surface (enable/disable, NIC selection, basic status) and bridge to JACK where possible.
- Enforce precise, group-based Polkit rules that align with Rivendell’s permission model.
- Package cleanly for Jammy/Noble and integrate smoothly with the offline installer.

## Scope and Non‑Goals

- In scope: JACK control with QJackCtl-level parity, Pulse/PipeWire disablement, Icecast/Liquidsoap config validation + control, Stereo Tool lifecycle, AES67 daemon abstraction (MVP: enable/disable, iface, status), backups and rollback.
- View-only for AudioStore: Do not change /etc/fstab or [AudioStore] in rd.conf; the current installer already manages this for Server/Client modes.
- Out of scope (for MVP): Deep core changes to Rivendell (see “Segue timing improvement” note below for future core work).

## Architecture Overview

- rdx-helper (system service, root):
  - Role: Privileged operations and service orchestration.
  - IPC: D-Bus (system bus) or Unix domain socket with JSON-RPC (choose one). D-Bus plays nicely with Polkit.
  - Responsibilities: Manage JACK, Icecast, Liquidsoap, Stereo Tool, AES67 daemons; config backups/tests/rollbacks; systemd units; Pulse/PipeWire disablement; logging.

- rdx-ui (Qt):
  - Option A: New pane embedded in RDAdmin (preferred long-term).
  - Option B: External Qt app “Rivendell Integrations” that looks/behaves like an RDAdmin panel and can be launched from RDAdmin.
  - Talks to rdx-helper via D-Bus/socket. Presents profiles, toggles, status.

- Config store:
  - /etc/rdx/ for system configs (root-owned).
  - /var/lib/rdx/ for state, backups, last-known-good, logs index.
  - User-level display-only mirroring permitted in ~/.config/rdx/ (no authority there).

- Logging:
  - /var/log/rdx/*.log per component plus a consolidated journal view from systemd.

- Security:
  - Polkit actions per method; local group gate (e.g., rivendell-integration-admin).
  - Map RD internal roles to membership in that group (see Permissions below).

## Feature Areas

### 1) JACK control (QJackCtl parity without Pulse)

- Primary controls:
  - Start/stop/restart jackd with a validated command line (e.g., /usr/bin/jackd -R -P99 -dalsa -dhw:… -r48000 -p1024 -n3).
  - Profiles: Named JSON configs with:
    - Driver (alsa/dummy/netjack), device (hw id), sample_rate, period, nperiods, realtime, priority, midi bridging on/off, environment (JACK_NO_AUDIO_RESERVATION=1, etc.).
  - Device discovery:
    - Enumerate ALSA devices (aplay -l/arecord -l) and render them; tag USB vs PCI.
  - Graph/patchbay:
    - Define persistent connection maps between JACK ports (parity with QJackCtl patchbay). Store as JSON; apply after server start and after clients appear (with retry).
  - Monitoring:
    - Show xruns count/rate; show CPU load; show transport state.
  - Startup ordering:
    - jackd first; Liquidsoap/Stereo Tool afterwards via systemd dependencies.

- Validation and rollback:
  - Preflight checks: verify device exists and is not busy; dry-run parameter validation (syntactic/semantic).
  - Apply new profile:
    - Graceful restart with staged config.
    - If jack fails to come up healthy within a grace period, restore last-known-good profile and restart.

- Profiles storage:
  - /etc/rdx/jack/profiles.d/<name>.json
  - Active symlink: /etc/rdx/jack/active.json
  - Backups: /var/lib/rdx/backups/jack/YYYYmmdd-HHMMSS-<name>.json

- QJackCtl migration:
  - Provide an importer that reads the current QjackCtl.conf and derives an initial profile and patchbay graph.

- No Pulse/PipeWire:
  - Never enable pulse-jack bridges.
  - Offer global toggles (see 2) to disable Pulse/PipeWire system-wide.

### 2) Pulse and PipeWire disablement

- Goals: No desktop/system audio interfering with broadcast chain; no accidental routing into JACK.
- Actions (configurable via rdx-ui with warnings):
  - Mask user-level PulseAudio (if present).
  - Mask PipeWire Pulse shim and audio session components on Noble.
  - Optionally purge PulseAudio/pipewire-audio packages on MATE-targeted boxes.
  - Guard rails:
    - Show prominent warnings; offer “Disable (recommended for studio)” and “Leave enabled (not recommended)” options.
    - Provide a one-click rollback (unmask/reinstall) if the user wants desktop audio later.
  - xRDP note:
    - Ensure xRDP audio redirection is off; document that we don’t support remote desktop audio in broadcast setups.

### 3) Icecast management

- Controls:
  - Start/stop/restart/status.
  - Config editor with templating for auth/ports/mounts.
  - Preflight:
    - Use built-in config test: icecast2 -t -c icecast.xml (return code gate).
  - Apply flow:
    - Write to /etc/icecast2/icecast.xml.new
    - Test; on success atomically move into place and restart; on failure retain old config and present errors.
  - Backup/rollback:
    - Keep versioned configs in /var/lib/rdx/backups/icecast/

### 4) Liquidsoap management

- Controls:
  - Start/stop/restart/status.
  - Manage multiple scripts if desired (e.g., main studio, backup feed).
  - Preflight:
    - Parse-check script (liquidsoap supports syntax/type checks depending on version; if unavailable, run in no-output dry mode and parse logs).
  - Apply flow:
    - Write script to /etc/rdx/liquidsoap/*.liq.new; validate; atomic swap; restart service.
  - JACK integration:
    - Ensure service requires jackd and applies patchbay graph after start.
  - Backup/rollback:
    - Version scripts and known-good link.

### 5) Stereo Tool orchestration

- Requirements:
  - Start/stop one or more instances reliably after JACK (and optionally after Liquidsoap).
  - Accept user-specified binary path(s), parameters, and JACK client names.
  - Manage instances as systemd services (user: rd or system-level) with:
    - Unit per instance: rdx-stereo-tool@<name>.service
    - After=rdx-jack.service; Wants=rdx-jack.service
    - Restart=on-failure; RestartSec=3
  - UI:
    - Manage a registry of instances (name, exec path, args, enable/disable autostart).
    - Start/stop and view logs per instance.
  - Backups:
    - Save instance definitions to /etc/rdx/stereotool/instances.json with versioned backups.

### 6) AES67 daemon control (pluggable)

- Abstraction:
  - Provide a provider interface for vendor/stack-specific AES67 daemons (e.g., Ravenna-based ALSA drivers, other AoIP).
  - MVP features:
    - Enable/disable the AES67 service.
    - Select network interface (ensuring PTP-capable NIC if needed).
    - Show basic status: running, PTP sync state (if accessible), stream count, RX/TX healthy.
  - Routing and JACK integration (MVP approach):
    - If the AES67 stack exposes ALSA devices, bridge via ALSA-JACK (zita-a2j/j2a) or jackd -dalsa -C/-P loops.
    - Expose simple “connect AES67 RX to JACK ports” and “connect JACK ports to AES67 TX” mapping UI (reuses patchbay).
  - Future:
    - Stream discovery/SDP join/leave, multicast tuning, IGMP hints, and a routing matrix UI that blends JACK ports and AES67 flows.
  - Backups/rollback:
    - Provider-specific config files versioned in /var/lib/rdx/backups/aes67/<provider>/

## Packaging Options (Jammy and Noble)

- Option A: .deb packages (recommended for helper+UI)
  - Pros:
    - Clean dependency resolution via apt.
    - Standard placement of systemd units, Polkit actions, config files.
    - Upgrades/rollbacks with dpkg; integrates with unattended upgrades if desired.
    - Clear versioning and uninstall story.
  - Cons:
    - For offline installs you must vendor dependencies or provide a local repo/cache.
  - Structure:
    - rdx-helper (Depends: systemd, polkitd, icecast2, liquidsoap, jackd2, qjackctl [optional], coreutils, jq)
    - rdx-ui (Depends: Qt libs; Recommends: rdx-helper)

- Option B: Vendored within the .run (self-contained)
  - Pros:
    - Fully offline, single deliverable.
    - No repo management needed.
  - Cons:
    - Bypasses dpkg database for files (unless you install .debs inside the .run).
    - Upgrades/uninstalls less clean; you must manage your own state and removal scripts.

- Option C: Hybrid (best of both)
  - The .run includes local .deb packages and installs them via dpkg -i, with a local cache for dependencies. You keep apt/dpkg hygiene and still support offline.

## Permissions and Polkit

- Linux group gate:
  - Create rivendell-integration-admin (or reuse an existing suitable group).
  - Only members can perform privileged actions.
- Rivendell role mapping:
  - Add a small sync task in rdx-helper: when an operator with RD Admin rights is configured (in Rivendell’s internal ACL), optionally reflect that by adding/removing their Linux account to rivendell-integration-admin.
  - Alternative: Keep a separate allowlist within rdx-helper to avoid implicit coupling.
- Polkit actions:
  - org.rivendell.rdx.jack.configure
  - org.rivendell.rdx.jack.control
  - org.rivendell.rdx.icecast.configure
  - org.rivendell.rdx.icecast.control
  - org.rivendell.rdx.liquidsoap.configure
  - org.rivendell.rdx.liquidsoap.control
  - org.rivendell.rdx.stereotool.configure
  - org.rivendell.rdx.stereotool.control
  - org.rivendell.rdx.aes67.configure
  - org.rivendell.rdx.aes67.control
- Policy:
  - Configure: auth_admin_keep for members of rivendell-integration-admin; deny others.
  - Control (start/stop/status): allow for rivendell-integration-admin without password; read-only status allowed for everyone.
  - Restrict to local sessions (subject to your xRDP usage model) to reduce remote privilege exposure.

## API Contract (rdx-helper)

- Transport: D-Bus system bus (recommended) or Unix domain socket JSON-RPC.
- Common response:
  - { ok: bool, error?: { code: string, message: string }, data?: any }
- Methods (selected):
  - jack.getProfiles() -> Profile[]
  - jack.applyProfile(name) -> ok
  - jack.getStatus() -> { running, xruns, sr, period, nperiods, device, uptime }
  - jack.restart() / jack.stop() / jack.start(profile?)
  - jack.setPatchbay(graph) -> ok; jack.getPatchbay()
  - system.audio.disablePulsePipewire(mode) -> ok; mode: disable|enable|purge|restore
  - icecast.getConfig() / icecast.testConfig(cfg) -> { ok, errors[] } / icecast.applyConfig(cfg) -> ok
  - icecast.start|stop|restart|getStatus
  - liquidsoap.listScripts() / getScript(name) / testScript(name, txt) / applyScript(name, txt)
  - stereotool.listInstances() / upsertInstance(def) / deleteInstance(name) / start|stop(name) / getStatus(name)
  - aes67.getProviders() / selectProvider(name) / enable(cfg) / disable() / getStatus()
  - system.backups.list(component) / restore(component, id)
  - logs.tail(component, N) / logs.bundle(components[]) -> path
- Error modes:
  - ValidationError, PreflightFailed, SystemdStartFailed, PermissionDenied, BusyDevice, UnknownProvider.

## Backups, Preflight, and Rollback

- All changes write to *.new and are preflight-tested when possible:
  - Icecast: native -t
  - Liquidsoap: parse/type-check; fallback to dry-run
  - JACK: device existence, syntactic checks; health probe post-start
  - AES67: provider-level checks (if any)
- On success: atomic rename and restart with bounded timeout; on failure: immediate rollback to last-known-good; surface errors in UI.
- Backup retention:
  - Keep N latest per component (configurable, default 10); rotate older.

## Installer Interplay (Jammy/Noble)

- The offline installer will:
  - Install rdx-helper and rdx-ui (.deb preferred; hybrid mode allowed).
  - Drop systemd units:
    - rdx-helper.service
    - rdx-jack.service (wrapping jackd via ExecStart from active profile)
    - rdx-stereo-tool@.service
    - rdx-liquidsoap@.service (if multi-script)
    - AES67 provider unit(s) when selected
  - Install Polkit actions to /usr/share/polkit-1/actions/ and the restrictive rule to rules.d
  - Create rivendell-integration-admin group; add rd to it by default.
  - Offer a toggle to disable Pulse/PipeWire (default: disabled on MATE studio hosts).
  - Do not touch AudioStore configuration paths.
  - Add desktop/menu shortcuts to launch the rdx-ui panel from RDAdmin or as a separate app.

## MVP Milestones and Acceptance

- Milestone 1 (JACK + disable Pulse/PipeWire + Icecast):
  - UI to pick device/profile and start JACK.
  - No Pulse/PipeWire running; confirmed after reboot; JACK stable; xrun counters visible.
  - Icecast config edit/test/apply with rollback.
- Milestone 2 (Liquidsoap + Stereo Tool orchestration):
  - Manage a main .liq script; preflight and restart.
  - Define and run one Stereo Tool instance with correct JACK wiring after jackd.
- Milestone 3 (AES67 basics):
  - Provider skeleton; enable/disable; pick NIC; status; simple JACK bridge via ALSA loopback.
- Tests:
  - Reboot persistence; recover from failed JACK profile; rollback on invalid Icecast/Liquidsoap configs; Polkit enforces group membership.

## Risks and Mitigations

- Disabling PipeWire breaks desktop audio:
  - Mitigation: Clear warnings, easy rollback, target MATE studio hosts, not general desktops.
- JACK device contention:
  - Preflight for in-use devices; guided remediation.
- AES67 diversity:
  - Pluggable providers; start with one well-supported stack; degrade gracefully.

## Notes for Future Core Work: Segue timing improvement

- Desired behavior:
  - If sweeper has a segue marker at t_s and next song has an intro of t_i, and t_i < remaining sweeper post-segue tail, delay next song start by (remaining tail - t_i) to prevent vocal clash.
- Sketch:
  - Let sweeper total length be T, segue marker at t_s, tail length L = T - t_s.
  - Start next song at time t_s + max(0, L - t_i).
  - Integrate into the Rivendell segue engine where sweeper-to-song transition is calculated; respect “No fade on segue.”
- This is a core patch to Rivendell’s scheduling/segue engine and should be handled in a separate fork/PR.

## Folder Structure (new project)

- src/
  - helper/ (rdx-helper daemon)
  - ui/ (Qt UI module/app)
  - providers/aes67/<provider-name>/
  - pkg/debian/ (debian/ control, postinst, rules, etc.)
- config/
  - polkit/actions/*.policy
  - polkit/rules.d/*.rules
  - systemd/*.service, templates
  - defaults/*.json
- docs/
  - operations.md (backup/rollback, troubleshooting)
  - security.md (Polkit actions, group model)
  - api.md (helper methods/contracts)
- tests/
  - integration/ (systemd/Polkit mocks, config preflight)

## Implementation Hints

- Languages:
  - Helper: Go or Python. Go provides static binaries and easy D-Bus bindings; Python is fast to iterate but requires careful vendoring for offline use.
  - UI: Qt (C++ or PySide). Qt C++ matches RDAdmin; PySide is faster to prototype (but increases runtime deps).
- IPC choice:
  - Prefer D-Bus for Polkit-native authorization and discoverability.
- Systemd:
  - Use template units and PartOf/Requires/After to encode sequencing (rdx-stereo-tool@.service After=rdx-jack.service).
- Patchbay:
  - Use jack_connect/jack_disconnect or libjack API for deterministic graph build with retries until ports appear.

---

If you want, I can next sketch the Polkit action XMLs and a sample D-Bus interface for the JACK portion, plus the systemd unit templates, as reference artifacts you can adapt in your new repo.




### Updates and obeservations: repo: rivendell-installer d43490a..9f74099  main -> main

If you run the TUI installer over ssh from an external terminal, it fails to initialize the default Rivendell db, then drop and restore our custom db. But, you can invoke RDDBConfig and use the "Create" button in the RDDB utility to initialize the default db with the root user and password, then tap the "Restore" button to manually restore the custom db (which overwrites the exisiting db).

Running sudo ./dist/rivendell-installer-0.1.1-20251019.run from the GUI terminal directly on the VM you want to install works. 

The ownership of: /var/snd needs to be set to -R rd:rivendell

Since the Rivendell installer isn't generating the test tone and dropping it in /var/snd, lets make sure it lands there, from: /root/rivendell-cloud/installer/offline/payload/999999_001.wav

The other thing that's slightly "off" is the audio inputs in Stereo Tool. for some reason, it routes the output of "System capture" to the input of Stereo Tool, and I have to manually swicth the output of Rivendell to the input of Stereo Tool in the ST settings (but I might need to recreate the Stereo Tool preset). Don't change anything about this issue, I'm just documenting it for reference later.

Double-clicking the "Add Cron Jobs" shortcut on the desktop to add the nightly sql backup to the crontab isn't executing the backup. Permissions are good and it's executable. Please fix this file so it executes the backup: /root/rivendell-cloud/installer/offline/payload/APPS/sql/daily_db_backup.sh

Running ./dist/rivendell-mate-bundle-24.04-0.1.1-20251019.run from a remote terminal to the VM successfully intstalls the MATE DE, then you can login to the dektop and run sudo ./dist/rivendell-installer-0.1.1-20251019.run from the GUI terminal directly on the VM and it applies the noble-only pypad sytax fix. 

On all of the above scenarios, I've only tested installing Riveendell in Standalone mode, so I still need to test server and client modes. 

Now that we have most of the kinks worked out, I want to explore the idea of forking the Rivendell project: https://github.com/ElvishArtisan/rivendell/tree/v4 and building a new module that controls all of the external features that we use and control externally: icecast2, qjackctl, vlc, vlc-plugin-jack, liquidsoap, jackd2, pulseaudio-module-jack, xRDP, etc. Is it possible to build all of those features into a new module or extend RDAdmin to control all of the parameters in one place? A couple examples; instead of having to edit /etc/icecast2/icecast.xml manually, we'd have an icecast menu that allows us to update: 
    <authentication>
        <!-- Sources log in with username 'source' -->
        <source-password>hackm3</source-password>
        <!-- Relays log in with username 'relay' -->
        <relay-password>hackm33</relay-password>

        <!-- Admin logs in with the username given below -->
        <admin-user>admin</admin-user>
        <admin-password>Hackm333</admin-password>
    </authentication>
and 
    <listen-socket>
        <port>8000</port>
        <shoutcast-mount>/192</shoutcast-mount>
        <shoutcast-mount>/stream</shoutcast-mount>
        <!-- <bind-address>127.0.0.1</bind-address> -->
        <!-- <shoutcast-mount>/stream</shoutcast-mount> -->
    </listen-socket>
In human readable text, without touching a line of code or the termianl. 
Like fields for:
- Source Password
- User Password
- Admin Username
- Admin Password
- Mount
- Add Mount(s)
And a button to APPLY (that eupdates the unlerying config and restarts the icecast systemd unit) with one click.
And similar controls for Liquidsoap (that can dynamically build the primary and new stream sources) with a few words. For reference, look at the /root/rivendell-cloud/installer/offline/payload/APPS/radio.liq

This is only a partial example. We'd need to look at all the options of each app that we want to be able to control interannly. 

I'd also like to add native support for AES67. Unless there's a better option, I've been looking at: https://github.com/bondagit/aes67-linux-daemon

What's possible? Please enlighten me. 




JACK: jackd args, qjackctl profiles, pulse-jack bridges
FYI: Rivendell is professional broadcast radio automation, so we don't use Pulse for anything. We should disable it altogether. We dont need system sounds, youtube videos, leaking in over-the-air audio.

Technically, RDAdmin has a control to start the jack server with a user defined command: /usr/bin/jackd -r -ddummy -r48000 -p1024... But I'd like to bake in more control. It would be awesome if we could extend the features of QJackCTL directly in (even if it's a new external module that tightly integrates with Rivendell). You can see my jack patches and config in: /root/rivendell-cloud/installer/offline/payload/APPS/configs/QjackCtl.conf. It would be great to bring full control of the primary functions directly into Rivendell instead of needing to use QJackCTL.

AudioStore: /etc/fstab + rd.conf [AudioStore]
- is already controlled and configured by the Rivendell appliance installer in Server and Client install modes, so we don't want to touch AudioStore or NFS. However, I still need to test Server and Client installs to see if our Rivendell insatller implements them the same way the Rivendell appliance script does and troubleshoot if it doesn't (not top priority right now).

Test config before restart when possible (icecast has a -t config test? If not, keep a backup and rollback on failure)
- Always create backups *of all feature settings* to roll-back in case of catastrophe.

- Forgot Stereo Tool integration: Mainly to start/stop Stereo Tool automatically. Startup apps and scripts are really flaky and unreliable. Right now, it has to be started manually after Jack, Icecast and Liquidsoap start. would be nice to have a switch and a field to plug in the path to the Stereo Tool executable (possibly start/stop multiple versions of Stereo Tool).

AES67 daemon control: enable/disable, iface, show basic status
- It would be awsome to build native AES67 driver support into Rivendell, so you can connect and route sources and destinations anywhere on the network to any i/o in Rivendell with some kind of matrix. Even better if AES67 can be mixed with Jack and not only one-or-the-other.


how this plays with your installer

The offline installer can:
Drop in the helper + Polkit rules + service unit
- I'll create a new project folder, then we can fork and download the current Rivendell v4 project. When we're done, then we can add this offline installer to the project to package it all up.

Packaging: For Jammy/Noble, prefer building .deb for helper + UI (or vend with your .run)
- Please explain in more deatil what the benefits and best options of each are.

Permissions: Polkit rules must be precise (limit methods, group-based)
- We should build on top of exisiting Rivendell permissions. Rivendell uses it's own internal users, groups, and permissins (separate from Linux).

Stability: Keep changes additive; avoid modifying Rivendell core unless strictly necessary
- Agreed (although there are a few things I'd like to fix in Rivendell core later). One of my biggest pet-peeves with Rivendell; let's say a song is ending and you have a :12 semi-produced "sweeper" (first :06 fully produced, last :06 dry and can lay over the next song intro by setting a segue marker at :06 and checking the "No fade on segue" toggle) going into the next song with a :04 intro. Right now, Rivendell will start the next song at the :06 mark of the sweeper and the last :02 seconds of the sweeper will clash with the vocals beginning at :04 into the next song. It should calculate the next song intro length and subtract that from the segue marker in the sweeper and wait :02 seconds, and start the song at :08). I'm not sure if I articulated that very well. 

Dont scaffold or edit anything yet. But you can create a bluprint that I'll copy to a new project where we'll fork Rivendell. 


