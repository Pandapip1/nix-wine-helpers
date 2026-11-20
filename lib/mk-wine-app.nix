# mkWineApp: wrap a prefix from mkWinePrefix into runnable commands plus a
# .desktop entry.
#
# At launch (see nix-wine-exec) the read-only store prefix gets a per-user
# overlay whose upper layer lives in
#   $XDG_DATA_HOME/nix-wine/<stateName>/<prefix-hash>/upper
# so settings survive between runs but a new prefix build starts fresh.
# The overlay is detached and handed to wine as WINEPREFIX=/proc/self/fd/N.
#
# The Windows profile is wired to the host with bind mounts (never symlinks):
#   1. (homeMapping = true) $HOME is mounted on C:\Users\<user>;
#   2. each XDG user dir that exists is mounted over its profile folder
#      (Desktop, Documents, Downloads, Music, Pictures, Videos);
#   3. (appDataMapping = true) AppData\Roaming -> $XDG_CONFIG_HOME,
#      AppData\Local -> $XDG_DATA_HOME, AppData\Local\Temp ->
#      $XDG_CACHE_HOME/nix-wine/<stateName>. The rest of AppData (LocalLow, ...)
#      lives in the state dir, so only an empty `AppData` mount-point stub is
#      left in $HOME.
{ lib
, symlinkJoin
, writeShellScriptBin
, makeDesktopItem
, bash
, coreutils
, util-linux
, nix-wine-exec
, defaultWine
}:
{ pname
, version ? "0"
, prefix # from mkWinePrefix
, wine ? prefix.wine or defaultWine
, exe # Windows path, e.g. "C:\\Program Files\\Foo\\foo.exe"
, args ? [ ]
, env ? { }
, dllOverrides ? { } # runtime WINEDLLOVERRIDES, { dll = "native,builtin"; }
, winedebug ? "-all"
, homeMapping ? true # mount $HOME on C:\Users\<user> (otherwise the profile stays inside the overlay)
, appDataMapping ? true # map AppData to the XDG config/data/cache dirs
, unixDrive ? true # recreate Z: -> / in the upper layer
  # extra host dirs: { "<bash expr>" = "<path relative to drive_c>"; }
, extraBinds ? { }
, stateName ? pname
, preRun ? ""
, postRun ? ""
, desktopName ? pname
, comment ? null
, icon ? null
, categories ? [ ]
, mimeTypes ? [ ]
, ...
}:
let
  username = prefix.username or "wineuser";
  prefixId = builtins.substring (builtins.stringLength builtins.storeDir + 1) 32 (toString prefix);
  profile = "drive_c/users/${username}";

  xdgDirs = [
    { name = "Desktop"; var = "XDG_DESKTOP_DIR"; def = "Desktop"; }
    { name = "Documents"; var = "XDG_DOCUMENTS_DIR"; def = "Documents"; }
    { name = "Downloads"; var = "XDG_DOWNLOAD_DIR"; def = "Downloads"; }
    { name = "Music"; var = "XDG_MUSIC_DIR"; def = "Music"; }
    { name = "Pictures"; var = "XDG_PICTURES_DIR"; def = "Pictures"; }
    { name = "Videos"; var = "XDG_VIDEOS_DIR"; def = "Videos"; }
  ];

  runtimeEnv = {
    USER = username;
    LOGNAME = username;
    WINEDEBUG = winedebug;
  } // lib.optionalAttrs (dllOverrides != { }) {
    WINEDLLOVERRIDES = lib.concatStringsSep ";" (lib.mapAttrsToList (d: m: "${d}=${m}") dllOverrides);
  } // env;

  setup = ''
    set -euo pipefail
    : "''${HOME:?HOME must be set}"
    export PATH=${lib.makeBinPath [ coreutils util-linux ]}:$PATH

    state_root="''${XDG_DATA_HOME:-$HOME/.local/share}/nix-wine/${stateName}/${prefixId}"
    mkdir -p "$state_root/upper" "$state_root/work"

    # one instance per upper layer: two overlays over one upper would corrupt it
    exec 9>"$state_root/lock"
    if ! flock -n 9; then
      echo "${pname}: already running (lock: $state_root/lock)" >&2
      exit 1
    fi

    ${lib.concatStrings (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}\n") runtimeEnv)}

    # user dirs: environment first, then user-dirs.dirs, then ~/<default> (as wine does)
    xdg_cfg="''${XDG_CONFIG_HOME:-$HOME/.config}/user-dirs.dirs"
    xdg_dir() {
      local v="''${!1:-}"
      if [ -z "$v" ] && [ -r "$xdg_cfg" ]; then v=$( . "$xdg_cfg" >/dev/null 2>&1; printf %s "''${!1:-}" ); fi
      printf %s "''${v:-$HOME/$2}"
    }

    binds=()
    ${lib.optionalString homeMapping ''binds+=(--bind "$HOME=${profile}")''}
    ${lib.concatMapStrings (d: ''
      dir=$(xdg_dir ${d.var} ${d.def})
      if [ -d "$dir" ] && [ "$dir" != "$HOME" ]; then binds+=(--bind "$dir=${profile}/${d.name}"); fi
    '') xdgDirs}
    ${lib.optionalString appDataMapping ''
      xdg_config="''${XDG_CONFIG_HOME:-$HOME/.config}"
      xdg_data="''${XDG_DATA_HOME:-$HOME/.local/share}"
      xdg_cache="''${XDG_CACHE_HOME:-$HOME/.cache}/nix-wine/${stateName}"
      mkdir -p "$xdg_config" "$xdg_data" "$xdg_cache/Temp" "$state_root/appdata"
      # mount-point directories are created through the mounts below them, so
      # back AppData itself with the state dir: its stubs then stay out of $HOME
      ${lib.optionalString homeMapping ''binds+=(--bind "$state_root/appdata=${profile}/AppData")''}
      binds+=(--bind "$xdg_config=${profile}/AppData/Roaming")
      binds+=(--bind "$xdg_data=${profile}/AppData/Local")
      binds+=(--bind "$xdg_cache/Temp=${profile}/AppData/Local/Temp")
    ''}
    ${lib.concatStrings (lib.mapAttrsToList (host: rel: ''
      binds+=(--bind "${host}=drive_c/${rel}")
    '') extraBinds)}

    mkexec() {
      exec ${nix-wine-exec}/bin/nix-wine-exec \
        --lower ${prefix} --upper "$state_root/upper" --work "$state_root/work" \
        --copy-up system.reg --copy-up user.reg --copy-up userdef.reg \
        ${lib.optionalString unixDrive "--symlink 'dosdevices/z:=/'"} \
        "''${binds[@]}" -- "$@"
    }
  '';

  # run `$@` (a wine command line) inside the overlay, then wait for wineserver
  inOverlay = ''
    mkexec ${bash}/bin/bash -c 'ec=0; "$@" || ec=$?; ${wine}/bin/wineserver -w; exit $ec' _ "$@"
  '';

  main = writeShellScriptBin pname ''
    ${setup}
    ${preRun}
    set -- ${wine}/bin/wine ${lib.escapeShellArg exe} ${lib.escapeShellArgs args} "$@"
    ${if postRun == "" then inOverlay else ''
      ( ${inOverlay} ) || ec=$?
      ${postRun}
      exit "''${ec:-0}"
    ''}
  '';

  wineCmd = writeShellScriptBin "${pname}-wine" ''
    ${setup}
    # ${pname}-wine winecfg | regedit | cmd | ...
    set -- ${wine}/bin/wine "$@"
    ${inOverlay}
  '';

  reset = writeShellScriptBin "${pname}-reset" ''
    state_root="''${XDG_DATA_HOME:-$HOME/.local/share}/nix-wine/${stateName}/${prefixId}"
    echo "Removing $state_root (the app's wine settings; files in your home are untouched)"
    chmod -R u+w "$state_root" 2>/dev/null || true
    rm -rf "$state_root"
  '';

  desktopItem = makeDesktopItem ({
    name = pname;
    inherit desktopName categories mimeTypes;
    exec = "${pname} %U";
    terminal = false;
  } // lib.optionalAttrs (comment != null) { inherit comment; }
  // lib.optionalAttrs (icon != null) { inherit icon; });
in
symlinkJoin {
  name = "${pname}-${version}";
  paths = [ main wineCmd reset desktopItem ];
  passthru = { inherit prefix; };
  meta.mainProgram = pname;
}
