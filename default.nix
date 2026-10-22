{
  lib,
  stdenvNoCC,
  makeWrapper,
  coreutils,
  gnused,
  gawk,
  diffutils,
  jujutsu,
  kakoune-unwrapped,
}:
stdenvNoCC.mkDerivation {
  pname = "jj-gutter-kak";
  version = "0.1.0";

  # Package the runtime files and build definition as a content-pinned source.
  src = builtins.path {
    path = ./.;
    name = "jj-gutter-source";
    filter = path: type:
      builtins.elem (builtins.baseNameOf path) [
        "default.nix" "rc" "lib" "jj-gutter.kak" "worker.sh" "map.awk" "quote.sh" "annotate.template"
      ];
  };
  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    plugin="$out/share/kak/autoload/plugins/jj-gutter"
    mkdir -p "$plugin"
    cp -R "$src/rc" "$src/lib" "$plugin/"
    chmod -R u+w "$plugin"
    substituteInPlace "$plugin/rc/jj-gutter.kak" \
      --replace-fail 'declare-option str jj_shell sh' 'declare-option str jj_shell ${stdenvNoCC.shell}'
    ${lib.getExe' gnused "sed"} -i \
      "s|^declare-option str jj_worker .*|declare-option str jj_worker $plugin/lib/worker.sh|" \
      "$plugin/rc/jj-gutter.kak"
    substituteInPlace "$plugin/lib/worker.sh" \
      --replace-fail 'JJ=jj' 'JJ=${lib.getExe jujutsu}' \
      --replace-fail 'DIFF=diff' 'DIFF=${lib.getExe' diffutils "diff"}' \
      --replace-fail 'KAK=kak' 'KAK=${lib.getExe' kakoune-unwrapped "kak"}'
    chmod +x "$plugin/lib/worker.sh"
    patchShebangs "$plugin/lib/worker.sh"
    wrapProgram "$plugin/lib/worker.sh" \
      --prefix PATH : ${lib.makeBinPath [ coreutils gnused gawk ]}
    runHook postInstall
  '';

  meta = {
    description = "Read-only live Jujutsu gutters and toggled Kakoune annotation column";
    platforms = lib.platforms.unix;
  };
}
