# nix-wine-helpers

Package Windows software for Linux with a wine prefix **built at Nix build time**
and shipped in the store.

```nix
let h = nix-wine-helpers.lib.mkHelpers pkgs; in
h.mkWineApp {
  pname = "foo";
  prefix = h.mkWinePrefix {
    name = "foo-prefix";
    windowsVersion = "win10";
    dllOverrides.d3d11 = "native,builtin";
    registry = [ ./foo.reg ];
    installers = [{ src = fooSetup; args = [ "/VERYSILENT" ]; }];   # or `files`, `steps`
    winetricksVerbs = [ "vcrun2019" ];
    winetricksCache.vcrun2019 = [{ name = "vc_redist.x64.exe"; src = fetchurl { ... }; }];
  };
  exe = "C:\\Program Files\\Foo\\foo.exe";
  desktopName = "Foo";
}
```

See `examples/hello` for a hermetic, buildable example (`nix build .#example-hello`).

## How it works

* **`mkWinePrefix`** runs `wineboot` + your steps under Xvfb in the sandbox and
  stores the result. It pins the Windows user (`wineuser`), removes
  `dosdevices/z:` and **fails the build if any symlink points outside the
  prefix**. Winetricks has no network in the sandbox, so downloads come from
  `winetricksCache` (`$W_CACHE/<verb>/<file>`).
* **`mkWineApp`** emits `<pname>`, `<pname>-wine` (run `winecfg`, `regedit`, …
  in the app's prefix) and `<pname>-reset`, plus a `.desktop` file.
* **`nix-wine-exec`** (`src/nix-wine-exec.c`) makes the store prefix usable
  without root: an overlayfs (store prefix below, per-user upper layer in
  `$XDG_DATA_HOME/nix-wine/<app>/<prefix-hash>/`) created in a private user+mount
  namespace with the new mount API and left **detached**; wine receives it as
  `WINEPREFIX=/proc/self/fd/N`. The merged root is owned by the user, so stock
  wine needs no patch.
* **Profile mapping** uses bind mounts, never symlinks: `$HOME` →
  `C:\Users\<user>` (`homeMapping`), then each existing XDG dir (environment,
  `user-dirs.dirs`, or `~/<Name>`) over Desktop/Documents/Downloads/Music/
  Pictures/Videos. `Z:` → `/` is re-created in the upper layer only.

## Caveats

* One running instance per app and prefix (a lock; a second overlay over the same
  upper layer would corrupt it).
* With `homeMapping`, wine creates `AppData` (and empty mount-point dirs such as
  `Documents`) in your real `$HOME`.
* Needs unprivileged user namespaces and overlayfs-in-userns (Linux ≥ 5.11).
  Ubuntu's `apparmor_restrict_unprivileged_userns` may block it.
* Prefix builds are not bit-reproducible (wine writes timestamps); `#time=` in the
  `.reg` files is normalised.
