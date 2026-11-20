# Takes a nixpkgs wine and returns one that can build a prefix with a frozen
# clock: wineboot's TSC calibration divides by the (zero) time delta otherwise
# (patches/wineboot-tsc-calibration-div0.patch). Used only while *building*
# prefixes; the prefix format is unchanged, so the stock wine runs the result.
wine:
wine.overrideAttrs (old: {
  pname = "${old.pname}-buildfix";
  patches = (old.patches or [ ]) ++ [ ../patches/wineboot-tsc-calibration-div0.patch ];
})
