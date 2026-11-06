# nx-fork-manager

A small Windows tool that keeps your Switch emulator forks up to date and tells you which fork to use for each game.

New fork builds come out almost every day. Without this tool you open the releases page, download the right zip, delete the old folder, extract the new one and only then play. This tool does all of that for you, keeps the previous version for rollback, and shows the best fork for each game from the [riyadhHDA/wichforks](https://github.com/riyadhHDA/wichforks) community guide.

It only installs ready-made release builds that the fork authors publish. It does not compile anything.

## Features

- Installs and updates forks from GitHub releases, GitHub Actions builds, and Forgejo releases.
- Verifies every download. It checks the SHA-256 when the source publishes one, and the file size otherwise.
- Keeps the previous version of each fork. You can roll back with one key, and a rollback pins the fork so the next update does not undo it.
- Never replaces a fork while it is running.
- Shows a "best fork per game" table from the wichforks guide, filtered by your GPU vendor (NVIDIA, AMD or Intel).
- Lets you record your own results per game. Your choice overrides the guide on your machine.
- Uses only built-in Windows tools: PowerShell 5.1 and `curl.exe`. There is nothing to install.

## Requirements

- Windows 10 (1803 or later) or Windows 11.
- An internet connection.
- Your own keys and firmware, dumped from your own console. This tool does not download keys, firmware or games.

## Quick start

1. Download this repository. Click **Code > Download ZIP** on GitHub and extract it, or run:

   ```bash
   git clone https://github.com/Schroederr/nx-fork-manager.git
   ```

2. Double-click `ForkManager.cmd`.
3. On the first run the tool creates `config.json`, detects your GPU vendor and downloads the wichforks guide.
4. Type a fork number and press Enter. The tool downloads that fork, installs it in the `forks` folder and opens it.

From then on, open the emulator through `ForkManager.cmd`. Each time it starts, it checks the installed forks and installs any new release before it shows the menu.

## The menu

```
FORKS
   1  Eglantine (Djihads80)    daily-20261105 (previous: build-212)
   2  Lichii                   build-75
   3  Lichii (git build)       not installed
   ...

GAMES
  g1  Mario Kart World                     SmileyTatsu (guide: SmileyTatsu)
  g3  Donkey Kong Bananza                  Selevet (guide: Selevet perf 3/4)
  ...
```

| Type | What it does |
|---|---|
| `2` | Opens fork 2. If it is not installed, the tool installs it first. |
| `g3` | Opens the recommended fork for game 3. |
| `n3` | Adds a note for game 3: which fork you tested, the result, and if that fork becomes your default for the game. |
| `r1` | Rolls fork 1 back to the previous version and pins it. |
| `p1` | Pins or unpins fork 1. A pinned fork does not get updates. |
| `u` | Checks for updates now, ignoring the check interval. |
| `b` | Opens `GAMES.md`, the full table with evidence from the guide and your notes. |
| `q` | Quits. |

Only installed forks get updates. A fork you never opened does not use disk space or API requests.

## Command line

You can also run single actions, for example from a scheduled task:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File fork-manager.ps1 -Action Update
```

| Action | What it does |
|---|---|
| `Menu` | Default. Interactive menu. |
| `Status` | Lists forks, installed versions and game recommendations. |
| `Check` | Shows the latest release of every fork (or of `-Fork <id>`) without installing. |
| `Update` | Updates all installed forks, or only `-Fork <id>`. |
| `Install -Fork <id> [-Tag <tag>]` | Installs the latest release, or a specific tag. |
| `Rollback -Fork <id>` | Swaps to the previous version and pins it. |
| `Pin -Fork <id>` / `Unpin -Fork <id>` | Stops or resumes updates for a fork. |
| `Open -Fork <id>` | Opens a fork, installing it first if needed. |
| `Sync` | Downloads the latest wichforks guide. |

Fork ids are in `forks.json` (for example `selevet`, `pokedinner`, `lichii-git`). For an Actions build, `-Tag` takes the build name, for example `-Tag build-80`.

## GitHub token (optional, recommended)

Without a token, GitHub allows 60 API requests per hour from your IP address. Each fork check uses one or two requests. To make sure it does not hit the limit, the tool checks each fork at most once per `check_interval_minutes`. If you still hit the limit, the tool tells you when it resets.

A token raises the limit to 5000 requests per hour. It also lets the tool download GitHub Actions builds directly from GitHub instead of through nightly.link.

1. Open <https://github.com/settings/personal-access-tokens/new>.
2. Give the token a name, set **Repository access** to **Public repositories**, and do not add any permissions.
3. Generate the token and copy it.
4. Save it as a user environment variable, then close and reopen `ForkManager.cmd`:

   ```bash
   setx GITHUB_TOKEN "paste-your-token-here"
   ```

The token is read-only and only reaches `api.github.com`. Do not share it, and do not put it in any file in this folder.

## Configuration

### config.json (your settings)

The first run creates this file. It is not tracked by git, so updates of this tool never overwrite it.

```json
{
  "gpu": "NVIDIA",
  "install_dir": "forks",
  "check_interval_minutes": 60
}
```

| Key | Meaning |
|---|---|
| `gpu` | `NVIDIA`, `AMD` or `Intel`. Hides guide recommendations for forks that the guide marks as not working on your GPU. Set it to `""` to turn off the filter. |
| `install_dir` | Where forks are installed. A relative path starts from this folder. An absolute path also works. In JSON, write backslashes twice: `"D:\\Emulators\\forks"`. |
| `check_interval_minutes` | How often the menu checks each fork. The `u` key ignores it. |

### forks.json (the fork catalog)

This file lists the forks the tool knows about. To add a fork, add an entry:

```json
{
  "id": "myfork",
  "name": "My Fork",
  "source": "github",
  "repo": "someone/MyFork",
  "include": "windows-x86_64.*\\.zip$",
  "exclude": "pgo|symbols",
  "exe": "myfork.exe",
  "aliases": ["MyFork"],
  "wichforks_id": null
}
```

| Key | Meaning |
|---|---|
| `id` | Short unique name. It is also the folder name in `install_dir`. |
| `name` | Name shown in the menu. |
| `source` | `github` (GitHub releases), `forgejo` (Forgejo or Gitea releases, needs `host`), or `actions` (newest successful GitHub Actions run, needs `workflow`). |
| `repo` | `owner/repository`. |
| `host` | Forgejo only. For example `git.eden-emu.dev`. |
| `workflow`, `branch` | Actions only. The workflow file name, and an optional branch. `null` means any branch. |
| `include`, `exclude` | Regular expressions for the release asset (or artifact) name. The first asset that matches `include` and does not match `exclude` is used. |
| `tags`, `release_exclude` | Optional. Regular expressions that skip releases by tag or by title, for example test branches or "experimental" builds. |
| `exe` | Main executable. If you leave it out, the tool uses the first `.exe` it finds. |
| `aliases` | Words that identify this fork in the wichforks game table. |
| `wichforks_id` | The fork id in the guide's `data/forks.json`. The GPU filter uses it. |

If you add a fork that others can use too, please open a pull request.

## How an update works

1. The tool asks the GitHub or Forgejo API for the newest release that matches the fork's rules.
2. It downloads the zip to `data\_tmp` and verifies the size and, when available, the SHA-256.
3. It extracts the zip and finds the folder with the main executable.
4. It moves the current version to `<install_dir>\_previous\<id>` and moves the new one into place. If a step fails, the current version stays as it was.
5. It records the version in `data\state.json`.

A verified hash proves that the file arrived intact. It does not prove that the build is safe. Only install forks whose authors you trust.

Most forks in the catalog are based on Eden/Eglantine and share the same user folder (`%APPDATA%\eden`), so your saves, keys and settings stay when you switch between forks or update them. If a fork runs in portable mode (a `user` folder next to the exe), the tool moves that folder to the new version.

## Files

| Path | Tracked by git | Content |
|---|---|---|
| `ForkManager.cmd` | yes | Launcher. |
| `fork-manager.ps1` | yes | The tool. |
| `forks.json` | yes | Fork catalog. |
| `config.json` | no | Your settings. |
| `GAMES.md` | no | Generated table of the best fork per game. |
| `data\state.json` | no | Installed and previous versions. |
| `data\my-notes.json` | no | Your notes per game. |
| `data\checks.json` | no | Time of the last check per fork. |
| `data\wichforks\` | no | Local copy of the guide. |
| `forks\` | no | Installed forks (default `install_dir`). |

To update the tool itself, download the new `fork-manager.ps1`, `forks.json` and `ForkManager.cmd`, or run `git pull`. Your settings, notes and installed forks are not touched.

## Troubleshooting

- **"GitHub API limit reached"**: wait until the time shown, or set a `GITHUB_TOKEN`.
- **"... is running. Close it and try again."**: close the emulator. The tool never replaces files in use.
- **"Build ... has no valid Windows artifact"**: GitHub deletes Actions artifacts after a few days. Use a newer build.
- **Windows SmartScreen or antivirus warnings**: these come from the emulator builds, not from this tool. Check the fork's release page if you are not sure.
- **A fork update broke a game**: type `r` and the fork number to go back. The fork stays pinned until you unpin it with `p`.

## Credits and disclaimer

- Game recommendations come from [riyadhHDA/wichforks](https://github.com/riyadhHDA/wichforks). The tool downloads the guide at run time and does not redistribute it.
- Actions builds without a token come through [nightly.link](https://nightly.link), a third-party service.
- This project is not affiliated with any fork, with the wichforks guide, or with Nintendo. It does not include or distribute emulators, keys, firmware or games. Each fork belongs to its authors and has its own license.

## License

[MIT](LICENSE)
