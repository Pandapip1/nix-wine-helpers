# mkWinePrefix: build a wine prefix at *build time* and keep it in the store.
#
# The result is a plain prefix directory ($out/drive_c, $out/*.reg, ...). It is
# read-only and must be run through an overlay (see mk-wine-app.nix), because a
# store path is neither writable nor owned by the user.
#
# Invariants enforced at build time:
#   * no symlink in the prefix points outside the prefix (so dosdevices/z: is
#     removed and the shell-folder links to $HOME are never created);
#   * the Windows user is a fixed name (default "wineuser"), which the runtime
#     launcher pins via $USER.
{ lib
, stdenvNoCC
, writeText
, xvfb-run
, winetricks
, cabextract
, unzip
, p7zip
, defaultWine
, patchBuildWine
, wine-determinism
}:
{ name
, wine ? defaultWine
, username ? "wineuser"
, windowsVersion ? "win10" # anything `winecfg -v` accepts
  # { dll = "native,builtin"; ... } written to HKCU\Software\Wine\DllOverrides
, dllOverrides ? { }
  # list of .reg files, derivations, or strings of .reg text, imported in order
, registry ? [ ]
  # winetricks verbs to run. Nix builds have no network, so every file a verb
  # downloads must be supplied via winetricksCache:
  #   { vcrun2019 = [ { name = "vc_redist.x64.exe"; src = fetchurl {...}; } ]; }
  # (winetricks looks in $W_CACHE/<verb>/<name> and verifies its own checksum)
, winetricksVerbs ? [ ]
, winetricksCache ? { }
  # [ { src = <drv|path>; args = [ "/VERYSILENT" ]; } ]; *.msi go through msiexec
, installers ? [ ]
  # { "Program Files/Foo" = <drv|path>; } copied into drive_c
, files ? { }
  # free-form shell run last, with $WINEPREFIX set and an X display available
, steps ? ""
  # DLL overrides used only while the prefix is created (skips the Mono/Gecko prompts)
, bootDllOverrides ? "winemenubuilder.exe=d;mscoree,mshtml=d"
, nativeBuildInputs ? [ ]
  # Make the build reproducible: wall-clock time is frozen at `buildTime`
  # (seconds since the Unix epoch) and random bytes (GUIDs) become a fixed
  # stream, via an LD_PRELOAD shim (src/wine-determinism.c); the build then
  # uses a wine with a wineboot fix (lib/wine-build-fixes.nix). Monotonic
  # clocks are untouched.
, buildWine ? (if reproducible then patchBuildWine wine else wine) # wine used only to *run* the build
, reproducible ? true
, buildTime ? 0
, ...
}@args:
let
  regFile = i:
    if builtins.isString i && !(lib.isStorePath i) then writeText "${name}.reg" i else i;

  isMsi = src: lib.hasSuffix ".msi" (lib.toLower (toString src));

  installerStep = i: ''
    ${if isMsi i.src
      then ''wine msiexec /i ${lib.escapeShellArg i.src} ${lib.escapeShellArgs (i.args or [ "/qn" ])}''
      else ''wine ${lib.escapeShellArg i.src} ${lib.escapeShellArgs (i.args or [ ])}''}
    wineserver -w
  '';

  cacheStep = verb: entries: lib.concatMapStrings (e: ''
    mkdir -p "$W_CACHE/${verb}"
    cp ${lib.escapeShellArg e.src} "$W_CACHE/${verb}/${e.name}"
  '') entries;

  copyStep = dest: src: ''
    mkdir -p "$(dirname "$WINEPREFIX/drive_c/${dest}")"
    cp -r --no-preserve=mode,ownership ${lib.escapeShellArg src} "$WINEPREFIX/drive_c/${dest}"
  '';

  buildSteps = ''
    set -euo pipefail
    ${lib.optionalString reproducible ''
      export LD_PRELOAD=${wine-determinism}/lib/libwine-determinism.so''${LD_PRELOAD:+:$LD_PRELOAD}
      export NIX_WINE_FIXED_TIME=${toString buildTime}
    ''}
    wine wineboot --init
    wineserver -w
    winecfg -v ${lib.escapeShellArg windowsVersion}
    wineserver -w

    ${lib.concatStrings (lib.mapAttrsToList (dll: mode: ''
      wine reg add 'HKCU\Software\Wine\DllOverrides' /v ${lib.escapeShellArg dll} /d ${lib.escapeShellArg mode} /f
    '') dllOverrides)}

    ${lib.concatMapStrings (r: ''
      wine regedit /S ${lib.escapeShellArg (regFile r)}
      wineserver -w
    '') registry}

    ${lib.optionalString (winetricksVerbs != [ ]) ''
      export W_CACHE="$TMPDIR/winetricks-cache"
      mkdir -p "$W_CACHE"
      ${lib.concatStrings (lib.mapAttrsToList cacheStep winetricksCache)}
      winetricks --unattended ${lib.escapeShellArgs winetricksVerbs}
      wineserver -w
    ''}

    ${lib.concatMapStrings installerStep installers}
    ${lib.concatStrings (lib.mapAttrsToList copyStep files)}

    ${steps}
    wineserver -w
  '';
in
stdenvNoCC.mkDerivation ({
  inherit name;
  dontUnpack = true;
  nativeBuildInputs = [ buildWine winetricks xvfb-run cabextract unzip p7zip ] ++ nativeBuildInputs;

  buildCommand = ''
    export HOME="$TMPDIR/home"; mkdir -p "$HOME"   # empty: no XDG dirs, so wine never creates shell-folder links
    export USER=${lib.escapeShellArg username} LOGNAME=${lib.escapeShellArg username}
    # wine refuses to create a prefix directly under /nix/store (parent not owned by us),
    # so build in $TMPDIR and move into $out at the end
    export WINEPREFIX="$TMPDIR/prefix" WINEDEBUG=''${WINEDEBUG:--all}
    export WINEDLLOVERRIDES=${lib.escapeShellArg bootDllOverrides}
    export LC_ALL=C.UTF-8

    cat > "$TMPDIR/steps.sh" <<'STEPS_EOF'
    ${buildSteps}
    STEPS_EOF
    xvfb-run -a -s "-screen 0 1280x1024x24" bash "$TMPDIR/steps.sh"

    wineserver -w || true
    wineserver -k || true

    # ---- normalise and verify -------------------------------------------------
    p="$WINEPREFIX"
    rm -f "$p/dosdevices/z:"
    rm -rf "$p"/drive_c/users/*/Temp/* "$p"/drive_c/windows/temp/* 2>/dev/null || true

    bad=0
    while IFS= read -r l; do
      case "$(readlink -m "$l")" in
        "$p"/*) ;;
        *) echo "error: symlink escapes the prefix: $l -> $(readlink "$l")" >&2; bad=1 ;;
      esac
    done < <(find "$p" -type l)
    [ "$bad" = 0 ]
    test -d "$p/drive_c/users/${username}"

    mv "$p" "$out"
  '';

  passthru = { inherit wine username; };
} // (builtins.removeAttrs args [
  "name" "wine" "username" "windowsVersion" "dllOverrides" "registry" "winetricksVerbs"
  "winetricksCache" "installers" "files" "steps" "bootDllOverrides" "nativeBuildInputs" "reproducible" "buildTime" "buildWine"
]))
