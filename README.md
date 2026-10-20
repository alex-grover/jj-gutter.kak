# jj-gutter.kak

Jujutsu (`jj`) change markers and a toggleable author/change/summary column for
Kakoune, including unsaved edits.

## How it works

Background jobs compare the buffer with `@-` (the working-copy revision's parent).
System `diff` locates changes; cached `jj file annotate` supplies blame.
Gutters retain cached results while updating; changed lines become `uncommitted`.
Source and history remain unchanged.

## Install

Requires Kakoune 2026.05.21, jj 0.46, `diff`, and Unix shell utilities on `PATH`.
Keep `rc/` and `lib/` together in the checkout. Choose one method:

### Manual

Add to `kakrc`:

```kak
source /path/to/jj-gutter.kak/rc/jj-gutter.kak
jj-enable
```

### plug.kak

After loading plug.kak, add:

```kak
plug "jj-gutter.kak" load-path "/path/to/jj-gutter.kak" config %{
    jj-enable
}
```

### Nix / Home Manager

Module (replace the path):

```nix
{ pkgs, ... }:
let
  source = builtins.path {
    path = /path/to/jj-gutter.kak;
    name = "jj-gutter-source";
    sha256 = "sha256-7ai+bOekafReEC8gA/pst8blBLwz/0kzlG2L4kDOKi0=";
    filter = p: _: builtins.elem (builtins.baseNameOf p) [
      "default.nix" "rc" "lib" "jj-gutter.kak"
      "worker.sh" "map.awk" "annotate.template"
    ];
  };
in {
  programs.kakoune.enable = true;
  programs.kakoune.plugins = [ (pkgs.callPackage source {}) ];
  programs.kakoune.extraConfig = "jj-enable";
}
```

Apply Home Manager; restart Kakoune.

## Use

Commands (`:`) in a jj workspace file:

- `jj-blame-toggle`: toggle this view's blame.
- `jj-refresh`: refresh immediately.
- `jj-disable` / `jj-enable`: stop / resume.

Markers: `+` added, `~` modified, `-` deleted, `*` mixed changes.
Existing line-number and diagnostic gutters are preserved.

Options (`set-option global`): `jj_blame_width` (40), `jj_check_seconds` (2),
`jj_show_blame` (false).

Supports text up to 1 MiB/10,000 lines and one working-copy parent.
Unsupported files clear visuals; inspect `echo %opt{jj_error}`.

Run tests with `sh tests/run.sh`.
