# PipPin

Pin any window as a small always-on-top box over your game. Watch Netflix or Prime Video in the corner while you play.

No install and no dependencies. It's a single PowerShell script that uses what already ships with Windows 10/11.

## Download and run

1. Download `PipPin.zip` from the [latest release](../../releases/latest).
2. Unzip it anywhere.
3. Double-click **`PipPin.cmd`**. A PipPin icon appears in the system tray.

Press **Ctrl+Alt+N** for Netflix or **Ctrl+Alt+A** for Prime Video. Or focus any window and press **Ctrl+Alt+P** to pin it.

## Hotkeys

| Keys | Action |
|---|---|
| Ctrl+Alt+P | Pin / unpin the focused window |
| Ctrl+Alt+G | Pin the window under the mouse |
| Ctrl+Alt+S | Cycle size |
| Ctrl+Alt+C | Cycle corner |
| Ctrl+Alt+T | Cycle transparency |
| Ctrl+Alt+H | Hide / restore the pinned window |
| Ctrl+Alt+N | Open Netflix in a small window and pin it |
| Ctrl+Alt+A | Open Prime Video in a small window and pin it |
| Ctrl+Alt+Q | Quit |

Size, corner, transparency and hide keep working while your game has focus.

The pinned window's title bar hides itself. Move the mouse over the window to bring it back. It hides again 5 seconds after the mouse leaves.

Right-click the tray icon for the same options. Double-click it to see the hotkeys.

## Requirements

- Windows 10 or 11
- Microsoft Edge or Google Chrome (for the Netflix / Prime Video windows)
- **Your game must run in Windowed or Borderless mode.** Exclusive fullscreen takes over the display, and nothing can sit on top of it.

## How it works

PipPin is a small WinForms tray app written in C#, embedded in a PowerShell script and compiled at launch with `Add-Type`. That's why it needs no installer or build step. It calls the Win32 API directly:

- **Global hotkeys:** `RegisterHotKey` lets the hotkeys work while the game has focus.
- **Always on top:** `SetWindowPos` with `HWND_TOPMOST` places and sizes the pinned window in the chosen corner of the current monitor.
- **Transparency:** `WS_EX_LAYERED` plus `SetLayeredWindowAttributes`. At full opacity the layered style is removed completely, because DRM-protected video can render black in layered windows.
- **Streaming windows:** Edge or Chrome is launched in `--app` mode (no tabs or address bar). A timer then finds the new window by its title with `EnumWindows` and pins it.
- **Auto-hiding title bar:** Chromium draws its title bar itself, so changing the window style doesn't remove it. PipPin clips the strip off with a window region (`SetWindowRgn`), sized for the window's DPI. It reapplies the clip whenever the browser resets it.

## Troubleshooting

- **Nothing happens when I double-click `PipPin.cmd`:** run `PipPin-Debug.cmd` instead. It keeps a console open so you can see any error.
- **"Some hotkeys are taken":** another app is already using that key combination. The other hotkeys still work.
- **The streaming window didn't pin itself:** click it and press Ctrl+Alt+P.
- **You have to sign in:** the first time, sign in to Netflix or Amazon inside the small window. It remembers you after that.

## License

MIT. See [LICENSE](LICENSE).
