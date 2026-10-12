<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Insomnia">
</p>

<h1 align="center">Insomnia</h1>

<p align="center">Keeps your Mac awake while it works, even with the lid closed.</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/menu-dark.png">
    <img src="docs/menu-light.png" width="340" alt="The Insomnia menu">
  </picture>
</p>

Insomnia lives in the menu bar. Start an export, a render, an upload or a coding agent, close the lid and put the Mac in your bag. The work carries on, and the Mac goes to sleep once it is done.

## Download

**[Download Insomnia](https://github.com/michalp1111/insomnia/releases/latest/download/Insomnia.zip)** for macOS 14 or later, on Apple silicon or Intel.

1. Open the downloaded `Insomnia.zip`, unless your browser already did, and drag **Insomnia** into your **Applications** folder.
2. Open Insomnia. It is not notarized by Apple yet, so the first time macOS refuses to open it. Click **Done**.
3. Go to **System Settings › Privacy & Security**, scroll down to the note about Insomnia and click **Open Anyway**, then confirm.

Insomnia now sits in the menu bar as a closed eye. Click it and flip the switch. The first time, macOS asks for your password once so that Insomnia can keep working with the lid closed. To have it start with your Mac, turn on **Open at Login** in its Settings.

## How it works

- **While Working** keeps the Mac awake only while something is actually working, and lets it sleep 5 minutes after everything finishes.
- **Until Turned Off** keeps it awake until you say otherwise.
- The eye in the menu bar opens while Insomnia holds the Mac awake, and the menu shows what is working.

While Working counts:

- **Apps that ask the Mac to stay awake**, as video editors do while they export and browsers while they download. macOS ignores these requests once the lid closes. Insomnia honors them.
- **Apps that keep the processor busy**, such as a 3D render or an encode.
- **Uploads**, like a finished video on its way to YouTube or to a client.
- **Coding agents**: Claude Code, Codex, Gemini CLI, Aider, OpenCode, Cursor Agent, Amp, Goose, Droid, Copilot CLI, Qwen Code, Crush, Cline, Auggie and Kiro, in a terminal or in the Claude app. An agent counts while data moves over its connections, while it runs a tool or while it keeps the processor busy, not while it sits waiting for you.
- **Apps you choose.** Add any app in Settings, and the Mac stays awake whenever it is open, busy or not.

<p align="center">
  <img src="docs/settings.png" width="420" alt="Insomnia settings">
</p>

Background system processes, such as Spotlight indexing, do not count. Everything stays on the Mac: Insomnia makes no network requests and collects nothing.

## The closed lid

macOS sleeps when the lid closes, whatever apps ask for. The only switch that overrides it is the system's `SleepDisabled` flag, and only an administrator can set it. The first time you turn Insomnia on, it asks for your password once and installs `/etc/sudoers.d/insomnia`, a rule that lets it run exactly these two commands without a password:

```
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
```

Nothing else gets elevated.

Safeguards:

- If Insomnia quits or crashes, a watchdog restores normal sleep within milliseconds.
- Below 10 % battery, or when the Mac runs too hot, Insomnia pauses.
- When the work is done and the lid is closed, Insomnia puts the Mac to sleep rather than leaving it running in your bag.

## Light on resources

Turned off, Insomnia does nothing at all. In Until Turned Off it only listens for system events. While Working takes a look of a millisecond or two every 10 seconds, or every 30 seconds while something works, which stays under 0.1 % of one CPU core and about 15 MB of memory.

## Build from source

Requires the Command Line Tools (`xcode-select --install`).

```bash
scripts/build.sh release --install
```

This builds a universal app and installs it to `/Applications`. No Xcode project is needed.

## Uninstall

Quit Insomnia and move it to the Trash. To remove the closed-lid permission as well, run this in Terminal:

```bash
sudo rm /etc/sudoers.d/insomnia
```

---

<p align="center">Made by <a href="https://www.linkedin.com/in/michalptacek/">Michal Ptacek</a></p>
