# HynisLoader

Looking for [Vietnamese](README_VN.md)?

**HynisLoader** is a jailbreak tweak for iOS that allows Minecraft: Bedrock Edition to load whole `renderer` folder from resource packs, functioning similarly to Draco Injector on Android.

The tweak works with **all Minecraft versions that using the RenderDragon engine**.

## How This Tweak Works

This tweak hooks the `fopen()` function when Minecraft calls it from `libsystem_c.dylib` to redirect the game to load whole `renderer` folder from active packs in `Global Resource Packs` instead of loading the corresponding original files.

## How to Use

- For jailbroken devices, download this tweak [here](https://github.com/congcq/HynisLoader/releases) and install it via Sileo/Zebra.

- For non-jailbroken (Jailed) devices, download `libhynisloader.dylib` [here](https://github.com/congcq/HynisLoader/releases) and inject it via `TrollFools` or directly into the main executable of the IPA file using sideloading apps like Esign, Ksign, Feather, etc. Then, install the injected IPA by signing with a certificate or through TrollStore (if available).

## Third Party

- [HyniSign](https://github.com/vanhoof/HyniSign): MIT License

- [fishhook](https://github.com/jevinskie/fishhook): [BSD-3 License](https://github.com/facebook/fishhook/blob/main/LICENSE)
