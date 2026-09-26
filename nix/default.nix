{
  lib,
  stdenvNoCC,
  fetchurl,
  _7zz,
  nix-update-script,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "roopam";
  version = "1.3.0";

  src = fetchurl {
    url = "https://github.com/sizhky/Roopam/releases/download/v${finalAttrs.version}/Roopam-${finalAttrs.version}.dmg";
    hash = "sha256-E0N/Y2z2bsB2+R6tRmJ2kaN3CynLWjqENM1C347s9Y4=";
  };

  nativeBuildInputs = [ _7zz ];
  sourceRoot = ".";

  unpackPhase = ''
    runHook preUnpack
    7zz x -snld "$src"
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/Applications"
    cp -R "Roopam.app" "$out/Applications/"
    runHook postInstall
  '';

  dontBuild = true;
  dontFixup = true;

  passthru.updateScript = nix-update-script { };

  meta = {
    description = "Custom Finder folder icons and Favorites sidebar glyphs for macOS";
    homepage = "https://github.com/sizhky/Roopam";
    changelog = "https://github.com/sizhky/Roopam/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.mit;
    maintainers = [ ];
    platforms = [ "aarch64-darwin" ];
    mainProgram = "Roopam";
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
})
