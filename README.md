> [!Note]
> The current project is new and may contain minor bugs. If you encounter any issues, please report them to us immediately, and we will fix them if possible.
> You can also contribute to this project.

Looking for [Vietnamese](README_VN.md)?

# Hynis Patcher

**Hynis Patcher** is a jailbreak tweak for iOS that allows Minecraft: Bedrock Edition to load `material.bin` files from resource packs, functioning similarly to MaterialBinLoader or Draco on Android.

The tweak works with most Minecraft versions using the RenderDragon engine.

## How This Tweak Works

This tweak hooks the `fopen()` function when Minecraft calls it from `libsystem_c.dylib` to redirect the game to load `material.bin` files from active packs in `Global Resource Packs` instead of loading the corresponding original files.

## How to Use

- For jailbroken devices, download this tweak [here](https://github.com/congcq/MaterialLoader/releases) and install it via Sileo/Zebra.

- For non-jailbroken (Jailed) devices, extract the .dylib file from inside the tweak and inject it directly into the main executable of the IPA file using sideloading apps like Esign, Ksign, Feather, etc. Then, install the injected IPA by signing with a certificate or through TrollStore (if available).

## Third Party

- [fishhook](https://github.com/jevinskie/fishhook): [BSD-3 License](https://github.com/facebook/fishhook/blob/main/LICENSE)