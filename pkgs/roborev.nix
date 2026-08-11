{ lib, stdenvNoCC, fetchurl }:

let
  version = "0.64.0";

  # Upstream publishes prebuilt release tarballs and a SHA256SUMS file; these
  # hashes come straight from it. There is no Go build here on purpose: the
  # release binaries are statically linked (static-pie), so they run as-is with
  # no interpreter to patch, and building from source would mean vendoring the
  # whole module graph for no benefit.
  sources = {
    "x86_64-linux" = {
      suffix = "linux_amd64";
      sha256 = "e97ea2b8fd9dfd7a580f731ca847aa170a5fa95387727b7ad2d6875b73b902e7";
    };
    "aarch64-linux" = {
      suffix = "linux_arm64";
      sha256 = "429a986d1140d49106803e95d11646e9b32efc053ee58b65baf30e1e0a0f472d";
    };
    "x86_64-darwin" = {
      suffix = "darwin_amd64";
      sha256 = "49bdcab049984220cebea98d3ade43c9bc7f79ab7aa7d5417a2d2f6995f72717";
    };
    "aarch64-darwin" = {
      suffix = "darwin_arm64";
      sha256 = "d95b34df5fd7c1b82ef55176a549f75ad2394f6d02272d42f47fddca2ba5ff19";
    };
  };

  src' =
    sources.${stdenvNoCC.hostPlatform.system}
      or (throw "roborev: no prebuilt release for ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "roborev";
  inherit version;

  src = fetchurl {
    url = "https://github.com/kenn-io/roborev/releases/download/v${version}/roborev_${version}_${src'.suffix}.tar.gz";
    inherit (src') sha256;
  };

  sourceRoot = ".";

  installPhase = ''
    runHook preInstall
    install -Dm755 roborev $out/bin/roborev
    install -Dm644 LICENSE $out/share/licenses/roborev/LICENSE
    runHook postInstall
  '';

  # The binary is static-pie, so the usual dynamic-linker checks find nothing
  # to fix and the default fixup would only strip it for no gain.
  dontPatchELF = true;
  dontStrip = true;

  meta = with lib; {
    description = "Continuous background code review database for coding agents";
    homepage = "https://roborev.io";
    downloadPage = "https://github.com/kenn-io/roborev/releases";
    license = licenses.mit; # MIT, per the LICENSE shipped in the release tarball
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    platforms = builtins.attrNames sources;
    mainProgram = "roborev";
  };
}
