# DynamicLake integration (verified 2026-09-18)

## Sources of truth used

- Installed DynamicLake Pro **1.9.7.5** on the development Mac.
- The current official [Create Your First Plugin](https://docs.dynamiclake.com/documentation/dynamiclakekit/createyourfirstplugin) guide.
- The current official [JSON Plugin API](https://docs.dynamiclake.com/documentation/dynamiclakekit/jsonpluginapi) reference.
- The current official [Plugin Packaging and Market](https://docs.dynamiclake.com/documentation/dynamiclakekit/pluginpackagingandmarket) reference.
- The current official [DynamicLakeKit repository](https://github.com/rokach/DynamicLakeKit---Dynamic-Island-Kit-for-Mac), whose README explicitly says JSON plugins do not need the SDK.
- The current official [System Monitor plugin repository](https://github.com/rokach/DynamicLake---System-Monitor-Plugin).
- Official DynamicLake Market packages installed by DynamicLake itself, including Safari Downloads, Chrome Downloads, and AI Agents.
- The official [DynamicLake Market announcement](https://www.dynamiclake.com/blog/dynamiclake-market-and-plugins).

The implementation follows the current official DocC schema and also verifies framed output against a deterministic local socket peer. The installed host and official packages are secondary compatibility evidence, not substitutes for the published schema.

## Why a Plugin

DynamicLake's official SDK README says JSON plugins send predefined JSON components and do not need DynamicLakeKit. Extensions use ExtensionKit and DynamicLakeKit when they need fully custom SwiftUI rendering. Transfer Center only needs documented native components, so a JSON Plugin is the lighter valid architecture.

## Package structure

```text
TransferCenter.dynamiclakeplugin/
├── plugin.json
├── transfer-center        # executable Mach-O
├── icon.png               # square PNG
├── drive-transfer-symbol.png # 96 px transparent inline activity artwork
└── PrivacyInfo.xcprivacy
```

The Market archive preserves this package directory as the single archive root: `TransferCenter-0.1.5.dynamiclakeplugin.zip`.

## plugin.json

Fields used by current official packages:

- `schemaVersion`: currently `1`
- `identifier`: reverse-DNS stable identifier
- `name`
- `version`
- `developerName`
- `description`
- `executable`: package-relative path
- `icon`: package-relative square PNG path
- `arguments`: launch arguments
- `autoStart`: boolean
- `settings`: host-rendered setting definitions

The manifest supports setting types including `switch` in the installed official packages. DynamicLake supplies setting values through `DYNAMICLAKE_PLUGIN_SETTINGS_PATH` and launch-snapshot environment variables.

## Launch and lifecycle

DynamicLake launches `executable` with the configured arguments. `autoStart: true` starts the process when the plugin is enabled. Package paths are relative to the package root. The process stays alive on the main run loop and exits when terminated by the host.

Environment used:

- `DYNAMICLAKE_JSON_SOCKET`: required Unix-domain socket path
- `DYNAMICLAKE_PLUGIN_SETTINGS_PATH`: live settings JSON path
- `DYNAMICLAKE_PLUGIN_PACKAGE`: package path (not needed by this implementation)
- `DYNAMICLAKE_PLUGIN_FEATURES`: comma-separated protocol capabilities; `presentSneakPeek` is checked before that field is sent

## IPC framing

The client connects to the local Unix-domain stream socket at `DYNAMICLAKE_JSON_SOCKET`. Every frame is:

1. 4-byte unsigned big-endian JSON byte length
2. UTF-8 JSON payload

The client enforces a 64 KiB frame ceiling, handles partial reads/writes, drains responses, and surfaces host rejection text to the bounded local debug log.

## Commands and callbacks

Commands used:

- `create`: requires `activityID` and `compactLiveActivity`
- `update`: updates the same stable `activityID`
- `dismiss`: removes the activity

Common top-level fields follow the official examples: `schemaVersion`, `requestID`, `type`, `activityID`, `title`, `priority`, `size`, `surfaces`, and feature-gated `presentSneakPeek`. Its value is a duration from 1 through 10 seconds, not a Boolean.

Host response frames use `type: "response"`, `ok`, and optional `error`. Interactive callbacks use `type: "action"`, `actionID`, and `activityID`.

## Surfaces and components

Surfaces used:

- `compactLiveActivity` with `leftSlot` and `rightSlot`
- `sneakPeek` with `leftSlot`, flexible `center`, and optional `rightSlot`

The current JSON API defines exactly those two surfaces. DynamicLake's native Swift extension API has an Extra Live Activity concept, but sending an invented `extraLiveActivity` JSON key can cause strict hosts to reject the whole command, so this plugin deliberately does not send one.

Components used by current official examples:

- `image`: `source: "sfSymbol"`, `systemImage`, optional `tint`
- `image`: `source: "inlineData"`, `mimeType: "image/png"`, and base64 data for the 4.8 KB transparent drive artwork
- `text`: `text`, `style` (`compact` or `marquee`), optional `tint`
- `progress`: optional normalized `value` and optional `tint`; omitting `value` makes it indeterminate
- `status`: `status` (`success`, `failed`, `inProgress`, `paused`, or `warning`) and optional `tint`
- `button`: `actionID`, `systemImage`, `shape`, optional `tint`

Each component in this project has a stable `id`.

## Host compatibility findings

Transfer Center conservatively normalizes Sneak Peek center text to one line and truncates it at 240 characters, matching the installed official plugin behavior observed during compatibility testing. It reads host `response` frames and logs rejection details rather than treating a successful socket write as host acceptance.

## Install and test workflow

1. Run `./scripts/build-release.sh`.
2. DynamicLake → Settings → Plugins → Install Local.
3. Select `TransferCenter.dynamiclakeplugin`.
4. For a deterministic host UI check, install `TransferCenter-Development.dynamiclakeplugin` instead; it launches with `--mock-transfer`, shows start/completion, and dismisses itself. The production package has no mock arguments.
5. For socket-only validation, run `scripts/socket-smoke.py` against the Release binary.

The development package proves package launch, framing, schema acceptance, and rendering. It does not prove Finder or hardware transfer detection.
