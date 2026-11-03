# FieldLab v8.6 | Live Update

FieldLab is a Roblox Bee Swarm Simulator helper script with Farm, Combat, Quest, Inventory, Plant, Toy/Blender, and configuration features.

## Start
1. Open [FieldLab_QuickStart.lua](./FieldLab_QuickStart.lua) from this repository.
2. Run that loader once in your chosen compatible Lua executor.
3. It checks `fieldlab_manifest.json` every 15 seconds for updates to `FieldLab_live.lua`.

## Files
- `FieldLab_QuickStart.lua`: standalone loader with a built-in fallback build; already configured for this repository.
- `FieldLab_live.lua`: current application code.
- `fieldlab_manifest.json`: version and SHA-256 of the application code.
- `FieldLab_LiveUpdate_README.md`: detailed setup and limitations.

## Cautions
- Auto-update fetches **executable code** from this public repository. Only enable it if you trust who can push to the repository.
- Reload temporarily stops running actions; settings are restored, but you must restart any Farm/Combat/Quest task.
- Rollback only handles compile and some startup errors, not every asynchronous/runtime error.
- This build is not verified by running it inside Roblox, and it may not work with every executor.
- The public repository exposes source code. Do not commit passwords, secrets or session tokens.

Repository owner: ERINARR.
