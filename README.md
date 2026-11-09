# nx-fork-manager

A small Windows tool that keeps your Switch emulator forks up to date and tells you which fork to use for each game.

New fork builds come out almost every day. Without this tool you open the releases page, download the right zip, delete the old folder, extract the new one and only then play. This tool does all of that for you, keeps the previous version for rollback, and shows the best fork for each game from the [riyadhHDA/wichforks](https://github.com/riyadhHDA/wichforks) community guide.

It only installs ready-made release builds that the fork authors publish. It does not compile anything.

## Features

- Installs and updates forks from GitHub releases, GitHub Actions builds, and Forgejo releases.
- Adds a new fork from a pasted link. The tool finds the Windows build and writes the rule for future builds.
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
| `a` | Adds a fork from a link. See [Add a fork from a link](#add-a-fork-from-a-link). |
| `x12` | Removes fork 12 and its installed files. This works only for forks you added. |
| `d4` | Deletes the installed files of build 4 (current and previous version). The fork stays in the list, so you can install it again by opening it. Works for every fork. Its zip backups stay. |
| `v` | Chooses the build type: MSVC (standard), PGO, or both. See [MSVC and PGO builds](#msvc-and-pgo-builds). |
| `z` | Sets how many downloaded zips to keep per fork: `0` (none), a number, or `all`. See `zip_backups` in [config.json](#configjson-your-settings). |
| `u` | Checks for updates now, ignoring the check interval. |
| `b` | Opens `GAMES.md`, the full table with evidence from the guide and your notes. |
| `s` | Your NX2 switches: add, turn on or off, delete. See [Custom NX2 switches](#custom-nx2-switches). |
| `q` | Quits. |

Only installed forks get updates. A fork you never opened does not use disk space or API requests.

## MSVC and PGO builds

Some forks publish two Windows builds of each release: the standard MSVC build (`...-windows-x86_64.zip`) and a PGO build (`...-windows-x86_64-pgo.zip`). A PGO build is optimized with a recorded profile of real use. It is often faster, but it is a different binary, so test it before you rely on it.

Press `v` in the menu to choose:

| Choice | Menu shows |
|---|---|
| `m` MSVC (default) | The standard build of every fork. |
| `p` PGO | The PGO build of forks that publish one, for example `Orchid (PGO)`. Forks without a PGO build show their standard build. |
| `b` both | Both builds as separate entries. |

A PGO build is a separate fork entry with its own id (`<id>-pgo`, for example `orchid-pgo`), its own folder (`<install_dir>\orchid-pgo`), its own version, rollback and pin. So it never replaces the MSVC build, and both can be installed side by side.

Updates follow the choice. The check when the menu opens updates the builds you already have, and lists the builds of your build type that the forks you use do not have yet. It never downloads those by itself: `u` (or `-Action Update`) installs them and then keeps every build of that fork the menu shows up to date. Opening a build also installs it. Forks you never opened stay uninstalled.

When you change the build type with `v`, the tool:

1. Lists the builds of the new type that the forks you use do not have yet, and offers to download them now. If you say no, nothing is downloaded until you press `u` (or open one of them). The check when the menu opens reminds you which are missing, but does not download them.
2. Lists the installed builds of the type you no longer selected, and offers to remove them. It removes a build only when the fork has a build of the new type installed. Otherwise the fork would have nothing installed and would stop getting updates, so that build is kept.

Installed builds outside your build type appear in their own section under the fork list, for example:

```
FORKS (builds: PGO)
   1  Eglantine (Djihads80) (PGO)    daily-20261106
   ...
  11  ZendNevs                       not installed

MSVC INSTALLED BUILDS (not your build type: no updates. d<number> removes one)
  12  Orchid                         v0.7.5
```

The numbering continues, so `12`, `r12`, `p12` and `d12` work on them as on any fork. They get no updates. The section is hidden when everything installed matches your build type. On the command line, `-Fork orchid-pgo` always works, whatever the choice.

Zip backups (`zip_backups`) are kept and counted per build, in `_zips\orchid` and `_zips\orchid-pgo`.

Forks with PGO builds have `"pgo": true` in `forks.json`. A fork you add from a link gets it automatically when its releases include a Windows PGO zip.

## Add a fork from a link

A new fork came out and it is not in the list? Type `a` in the menu and paste its link. These links work:

| Link | Example |
|---|---|
| GitHub repository, releases page or release | `https://github.com/Frizti/Lichii/releases/tag/frizti-v1` |
| Forgejo or Gitea repository | `https://git.eden-emu.dev/Franseven/PokeDinner-a-Eglantine-Fork` |
| GitHub Actions workflow, for forks that publish builds only through Actions | `https://github.com/zortos293/Lichii/actions/workflows/release-binaries.yml` |

The tool then:

1. Reads the newest releases (or the newest successful Actions runs) and picks the Windows `.zip`. It prefers MSVC builds and skips Linux, macOS, Android, ARM, debug and symbol files. If there is also a Windows PGO zip, it saves a second rule for it (`pgo_include`), so the fork also gets a PGO entry.
2. Turns the file name into a rule that also matches future builds. For example, `selevet-eglantine-performance-7-windows-x86_64.zip` becomes `^selevet-eglantine-performance-\d+[a-z]?-windows-x\d+[a-z]?_\d+[a-z]?\.zip$`.
3. Checks that the rule finds the same build, and saves the fork in `my-forks.json`.
4. If the wichforks guide knows the fork, takes its name and id, so the fork shows up in the game recommendations and the GPU filter.
5. Asks if you want to install and open it now.

Forks you add get a `*` in the menu. `my-forks.json` is not tracked by git, so updates of this tool keep your forks.

If the tool picks the wrong file, or the fork renames its files later, edit the `include` and `exclude` rules in `my-forks.json`. The keys are the same as in `forks.json` (see [forks.json](#forksjson-the-fork-catalog)).

If a fork has no Windows build yet, the tool says so and adds nothing. Try again after the author publishes one.

## Custom NX2 switches

Most forks ship an `nx2_switches.txt` next to the exe: one `NAME=VALUE` per line, read at every start. An update replaces it with the fork's new version. With `s` in the menu you keep a list of switches that the tool writes into the `nx2_switches.txt` of every installed fork, again after every update.

```
MY NX2 SWITCHES (written to nx2_switches.txt of every installed fork)
   1  [on ]  EDEN_NX2_ASYNC_SKIP=0               Pipelines still building are waited for instead of skipped.
   2  [on ]  EDEN_NX2_PRELOAD_ALL_PIPELINES=1
   3  [off]  EDEN_NX2_SPLIT=2                    Offload GPU method/macro execution to the back thread (SPLIT=2 deli...

  a    add or change one switch (NAME=VALUE)   p  paste several   c  add all from the clipboard
  1    turn switch 1 on or off   x1  delete switch 1   r  re-apply to all forks
  i1   show switch 1 in full   n1  write your own description for switch 1   Enter  back
```

Each switch can have a description, shown next to it and cut to the window width (`i1` shows it in full). It comes from:

1. The comment above the switch in what you paste or copy (`p`, `c`). A comment above several lines describes all of them.
2. Otherwise, the comment above that switch in the `nx2_switches.txt` of your installed forks (the shipped copy). This is read from disk: no GitHub requests.
3. Your own text: `n1` writes or replaces the description of switch 1, and `-` clears it. A description you wrote or cleared is never replaced.

There is no complete official list of switches. The forks' `NX2_NOTES.md` files explain some older ones.

To add many switches at once, for example lines copied from another fork's `nx2_switches.txt`:

- `p`: paste the lines, then type `end` on its own line. (A blank line cannot end the paste, because switch files contain blank lines.)
- `c`: copy the lines first, then press `c`. The tool reads the clipboard, nothing to paste.

Blank lines and comment lines are skipped, also disabled examples such as `#EDEN_NX2_SPLIT=1`. A name you already have gets the new value and is turned on. Lines that are not `NAME=VALUE` are listed in a warning and skipped.

For each switch that is on:

- If the file already sets it (an active `NAME=...` line), the tool writes your value there and keeps the old line as a comment: `# nx-fork-manager: was EDEN_NX2_ASYNC_SKIP=0`.
- Otherwise it adds the line at the end of the file:

  ```
  ## CUSTOM nx-fork-manager ##
  EDEN_NX2_PRELOAD_ALL_PIPELINES=1
  ## END CUSTOM nx-fork-manager ##
  ```

  A commented-out example such as `#EDEN_NX2_SPLIT=1` does not count as set, so it stays as it is.

The first time, the tool copies the file as shipped to `nx2_switches.original.txt` in the same folder. It always builds `nx2_switches.txt` from that copy plus the switches that are on. So turning a switch off restores the fork's own value, and with every switch off the file is exactly the original again. Do not edit `nx2_switches.txt` by hand in a fork folder: the next change of your switches overwrites it. A fork without `nx2_switches.txt` is skipped.

Changes apply to every installed fork right away. Restart a running emulator to load them. Your list is saved in `config.json` (`nx2_switches`). As long as the list is empty, the tool does not touch any fork folder.

The forks also read `%APPDATA%\eden\nx2_switches.txt`, and a value there wins over the fork's file. If a switch has no effect, check that file.

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
| `Add -Url <link>` | Adds a fork from a link. |
| `Remove -Fork <id>` | Removes a fork you added, with its installed files. |

Fork ids are in `forks.json` (for example `selevet`, `pokedinner`, `lichii-git`). For an Actions build, `-Tag` takes the build name, for example `-Tag build-80`.

## 403 errors and the GitHub API limit

### The problem

Without a login, the GitHub API accepts only **60 requests per hour per IP address**. When the limit runs out, GitHub answers `403 rate limit exceeded` and the tool shows:

```
GitHub API limit reached (60 requests per hour without a token). Resets at 21:14. Set GITHUB_TOKEN for a limit of 5000.
```

You reach the limit faster than you expect, because:

- Each fork check uses one request, and an Actions build ("git build") uses two or more. The guide sync uses two or three.
- Every program on your network shares the same 60 requests: other launchers, browser extensions, another PC on the same router, or a VPN exit that many people use.
- An answer of "nothing changed" (HTTP 304) still counts.
- Pressing `u` several times, or running `-Action Check` for all forks, uses many requests at once.

The file downloads themselves do not count. Only the API questions ("what is the latest release?") count.

### What the tool already does

- The menu checks each fork at most once per `check_interval_minutes` (60 by default). A second start within the hour uses no requests.
- When the limit runs out, the tool stops asking GitHub, shows the reset time once, and keeps your installed versions as they are. Forgejo forks (PokeDinner) still update, because the limit is GitHub only.
- A fork that failed to update is checked again next time, so nothing is skipped for good.

### The fix: a GitHub token (recommended)

A token raises the limit to **5000 requests per hour**, only for you. It also lets the tool download Actions builds directly from GitHub instead of through nightly.link. It is free and takes two minutes:

1. Sign in to GitHub. If you do not have an account, create one.
2. Open <https://github.com/settings/personal-access-tokens/new>.
3. Give the token a name, for example `nx-fork-manager`. Choose an expiration date.
4. Under **Repository access**, choose **Public repositories**. Do not add any permissions. A token without permissions can only read public data.
5. Click **Generate token** and copy it. It starts with `github_pat_`.
6. Open a Command Prompt and save the token as a user environment variable:

   ```bash
   setx GITHUB_TOKEN "paste-your-token-here"
   ```

7. Close every open `ForkManager.cmd` window and open it again. `setx` affects only windows opened after it.

To check that the token works, open a new Command Prompt and run:

```bash
curl -s -H "Authorization: Bearer %GITHUB_TOKEN%" https://api.github.com/rate_limit
```

The `core` section must show `"limit": 5000`. Without the header the same command shows how much of the 60 is left on your IP address.

The tool sends the token only to `api.github.com`. Do not share it, do not paste it in chats or issues, and do not save it in any file in this folder. If it leaks, delete it on the same GitHub page and create a new one.

### Without a token

- Wait until the reset time the tool shows, then open it again.
- Raise `check_interval_minutes` in `config.json`, for example to `180`.
- Do not press `u` repeatedly. Normal starts are enough.
- Install only the forks you use. Forks you never opened are never checked.

### Other GitHub errors

- **"GitHub rejected GITHUB_TOKEN (401 Bad credentials)"**: the token expired or was deleted. Create a new one and run `setx` again, or remove it with `reg delete HKCU\Environment /v GITHUB_TOKEN /f` to go back to the 60-per-hour limit.
- **"GitHub refused the request (403)" without "limit reached"**: GitHub's short-term abuse protection. Wait a few minutes.

## Configuration

### config.json (your settings)

The first run creates this file. It is not tracked by git, so updates of this tool never overwrite it.

```json
{
  "gpu": "NVIDIA",
  "build_type": "msvc",
  "install_dir": "forks",
  "check_interval_minutes": 60,
  "zip_backups": 0,
  "nx2_switches": []
}
```

| Key | Meaning |
|---|---|
| `gpu` | `NVIDIA`, `AMD` or `Intel`. Hides guide recommendations for forks that the guide marks as not working on your GPU. Set it to `""` to turn off the filter. |
| `build_type` | `msvc` (default), `pgo` or `both`. Which builds the menu shows and updates. The `v` key changes it. If the key is missing, `msvc` is used. |
| `install_dir` | Where forks are installed. A relative path starts from this folder. An absolute path also works. In JSON, write backslashes twice: `"D:\\Emulators\\forks"`. |
| `check_interval_minutes` | How often the menu checks each fork. The `u` key ignores it. |
| `zip_backups` | Downloaded zips to keep per fork in `<install_dir>\_zips\<id>`. `0` keeps none (default), a number keeps that many of the newest, `"all"` keeps every zip. The `z` key in the menu changes it. A lower number deletes the oldest extra zips right away. If the key is missing, no zips are kept. |
| `nx2_switches` | Your NX2 switches, each `{ "name", "value", "enabled", "note" }` (`note` is the description). Easiest to change with `s` in the menu. See [Custom NX2 switches](#custom-nx2-switches). |

### forks.json (the fork catalog)

This file lists the forks that ship with the tool. To add a fork for yourself, use `a` in the menu: it writes the same kind of entry to `my-forks.json`. To add a fork for everyone, add an entry here and open a pull request:

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
| `include`, `exclude` | Regular expressions for the release asset (or artifact) name. The first asset that matches `include` and does not match `exclude` is used. Names with `pgo` never count as the standard build. |
| `pgo`, `pgo_include` | Optional. `"pgo": true` adds a PGO entry (`<id>-pgo`) that takes only names with `pgo`. It uses `pgo_include` when set, otherwise `include`, and `exclude` without its `pgo` part. |
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
6. If `zip_backups` is not `0`, it moves the zip to `<install_dir>\_zips\<id>\<tag>_<file>.zip` and deletes the oldest zips beyond the limit. Otherwise it deletes the zip.
7. If you have NX2 switches, it copies the new `nx2_switches.txt` to `nx2_switches.original.txt` and writes your switches into `nx2_switches.txt`.

A verified hash proves that the file arrived intact. It does not prove that the build is safe. Only install forks whose authors you trust.

Most forks in the catalog are based on Eden/Eglantine and share the same user folder (`%APPDATA%\eden`), so your saves, keys and settings stay when you switch between forks or update them. If a fork runs in portable mode (a `user` folder next to the exe), the tool moves that folder to the new version.

## Files

| Path | Tracked by git | Content |
|---|---|---|
| `ForkManager.cmd` | yes | Launcher. |
| `fork-manager.ps1` | yes | The tool. |
| `forks.json` | yes | Fork catalog. |
| `config.json` | no | Your settings. |
| `my-forks.json` | no | Forks you added from links. |
| `GAMES.md` | no | Generated table of the best fork per game. |
| `data\state.json` | no | Installed and previous versions. |
| `data\my-notes.json` | no | Your notes per game. |
| `data\checks.json` | no | Time of the last check per fork. |
| `data\wichforks\` | no | Local copy of the guide. |
| `forks\` | no | Installed forks (default `install_dir`). |
| `forks\_zips\` | no | Zip backups, when `zip_backups` is not `0`. |
| `forks\<id>\nx2_switches.original.txt` | no | The fork's `nx2_switches.txt` as shipped, when you use NX2 switches. |

To update the tool itself, download the new `fork-manager.ps1`, `forks.json` and `ForkManager.cmd`, or run `git pull`. Your settings, notes and installed forks are not touched.

## Troubleshooting

- **"GitHub API limit reached" or 403**: see [403 errors and the GitHub API limit](#403-errors-and-the-github-api-limit).
- **"No release of ... has a Windows .zip"** when you add a fork: the fork has no Windows build yet, or only publishes Actions builds. Paste the workflow link instead.
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
