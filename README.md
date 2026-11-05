# turn-off-display-when-external-connected

A macOS menu bar app that turns off the built-in display while a selected external monitor is connected, and restores it when disconnected.

Requires an Apple Silicon MacBook running macOS 13 or later. Uses an undocumented macOS display API.

## Run

```sh
bash scripts/build.sh
open "build/Panel Off.app"
```

Select your external monitor from the menu bar app to enable automation.

## Tests

```sh
bash scripts/test.sh
```
