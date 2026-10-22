#!/usr/bin/env nu
# otp-audit.nu: gate the Erlang/OTP version (task audit:otp; #18).
#
# Fails when any of these is below the OTP floor, or differs from the mise.toml erlang pin:
#   - the mise.toml `[tools] erlang` pin (must be a numeric string; a list or `latest` FAILs);
#   - the running ERTS, read from releases/<otp_release>/OTP_VERSION under code:root_dir()
#     (otp_release alone is the major, "28", and cannot see the patch level);
#   - every Erlang-bearing FROM line in the root Dockerfile*/Containerfile* (not recursive).
# Fails closed: an unreadable pin, runtime or image OTP, an image file without FROM lines, or an
# image reference built from `$ARG` is a FAIL. ARG defaults are not resolved, because a
# --build-arg can override them at build time; pin a literal tag instead.
# Every reason is listed in one FAIL line. Comparison is numeric per component, never by string.
#
# Tests: test/test-otp-audit.nu (decision defs and main, with a fake erl on PATH).

const repo = (path self | path dirname | path dirname)
# Lowest OTP with fixes for CVE-2026-55953 (28.5.0.4), CVE-2026-89422 (28.5.0.7), and CVE-2026-105236,
# CVE-2026-94200 plus follow-up fixes for CVE-2026-42789 and CVE-2026-48856 (28.5.0.8).
# Raising it is a one-line change here plus the matching T6 assertion in test/test-audit-wiring.nu.
const otp_floor = "28.5.0.8"

const erl_eval = 'F = filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"]), case file:read_file(F) of {ok, B} -> io:put_chars(B), halt(0); E -> io:format(standard_error, "~p~n", [E]), halt(1) end.'

def version-parts [version: string]: nothing -> list<int> {
  $version | split row "." | each {|part| $part | into int }
}

# true when version a is below version b, comparing components as integers.
# Raises on any non-numeric component, in either argument.
export def version-below [a: string, b: string]: nothing -> bool {
  let pa = (version-parts $a)
  let pb = (version-parts $b)
  let width = ([($pa | length) ($pb | length)] | math max)
  for i in 0..<$width {
    let x = ($pa | get -o $i | default 0)
    let y = ($pb | get -o $i | default 0)
    if $x < $y { return true }
    if $x > $y { return false }
  }
  false
}

# tools.erlang from a parsed mise.toml: a string as is, a record's `version`; null otherwise.
export def erlang-pin [mise_toml: record] {
  let value = ($mise_toml | get -o tools | default {} | get -o erlang)
  match ($value | describe) {
    "string" => $value
    $t if ($t | str starts-with "record") => {
      let version = ($value | get -o version)
      if ($version | describe) == "string" { $version } else { null }
    }
    _ => null
  }
}

# First whitespace-separated token of an OTP_VERSION file ("28.5.0.8 **\n" -> "28.5.0.8").
export def otp-version-from-file [text: string]: nothing -> string {
  let trimmed = ($text | str trim)
  if $trimmed == "" { "" } else { $trimmed | split row --regex '\s+' | first }
}

# {match, otp} for one image reference. match: the image is Erlang-bearing.
def image-otp [ref: string]: nothing -> record<match: bool, otp: any> {
  if ($ref | str contains "$") { return {match: true, otp: null} }
  let comps = ($ref | split row "@" | first | split row "/")
  let last = ($comps | last)
  let name = ($last | split row ":" | first)
  let tag = if ($last | str contains ":") { $last | split row ":" | skip 1 | str join ":" } else { null }
  let path = ($comps | drop 1 | append $name)
  let first = ($path | first)
  let path = if ($path | length) > 1 and (($first | str contains ".") or ($first | str contains ":") or $first == "localhost") { $path | skip 1 } else { $path }
  let path = if ($path | length) > 1 and ($path | first) == "library" { $path | skip 1 } else { $path }
  let joined = ($path | str join "/")
  let hexpm_elixir = ($joined | str ends-with "hexpm/elixir")
  let hexpm_erlang = ($joined | str ends-with "hexpm/erlang")
  let base = ($path | last)
  if not ($hexpm_elixir or $hexpm_erlang or $base in ["elixir" "erlang"]) { return {match: false, otp: null} }
  if $tag == null { return {match: true, otp: null} }
  let hit = if $hexpm_elixir {
    $tag | parse --regex '-erlang-(?<v>\d+(?:\.\d+)*)(?:-|$)'
  } else if $hexpm_erlang or $base == "erlang" {
    $tag | parse --regex '^(?<v>\d+(?:\.\d+)*)(?:-|$)'
  } else {
    []
  }
  {match: true, otp: (if ($hit | is-empty) { null } else { $hit.0.v })}
}

# One record per Erlang-bearing FROM line. Zero FROM lines gives one null-otp record (fail closed).
export def image-otps [file: string, text: string]: nothing -> list<record<file: string, line: int, image: string, otp: any>> {
  let froms = ($text | lines | enumerate | each {|e|
    let m = ($e.item | parse --regex '(?i)^\s*FROM\s+(?<rest>.*)$')
    if ($m | is-empty) { null } else { {line: ($e.index + 1), rest: $m.0.rest} }
  } | compact)
  if ($froms | is-empty) { return [{file: $file, line: 0, image: "", otp: null}] }
  $froms | each {|f|
    let ref = ($f.rest | split row --regex '\s+' | where {|t| $t != "" and not ($t | str starts-with "--") } | get -o 0 | default "")
    let r = (image-otp $ref)
    if $r.match { {file: $file, line: $f.line, image: $ref, otp: $r.otp} } else { null }
  } | compact
}

def numeric [value]: nothing -> bool {
  if ($value | describe) != "string" { return false }
  try { version-below $value $value | ignore; true } catch { false }
}

# Reasons for one numeric version against the floor and (when numeric) the pin.
# subject names the version in the reason, e.g. "runtime 28.3.2".
def version-reasons [subject: string, version: string, floor: string, pin, pin_ok: bool]: nothing -> list<string> {
  let below = if (version-below $version $floor) { [$"($subject) below floor ($floor)"] } else { [] }
  let differs = if $pin_ok and ((version-below $version $pin) or (version-below $pin $version)) {
    [$"($subject) differs from pin ($pin)"]
  } else {
    []
  }
  $below | append $differs
}

# Decision for one audit. Never raises; pass is true exactly when reasons is empty.
export def otp-verdict [floor: string, pin, runtime, images: list]: nothing -> record<pass: bool, reasons: list<string>> {
  if not (numeric $floor) {
    return {pass: false, reasons: [$"floor not numeric: ($floor)"]}
  }
  let pin_ok = (numeric $pin)
  let pin_reasons = if not $pin_ok {
    [$"erlang pin missing or not numeric: ($pin)"]
  } else if (version-below $pin $floor) {
    [$"pin ($pin) below floor ($floor)"]
  } else {
    []
  }
  let runtime_reasons = if $runtime == null {
    ["runtime OTP version unreadable"]
  } else if not (numeric $runtime) {
    [$"runtime ($runtime) not numeric"]
  } else {
    version-reasons $"runtime ($runtime)" $runtime $floor $pin $pin_ok
  }
  let image_reasons = ($images | each {|i|
    let loc = $"($i.file):($i.line)"
    if $i.otp == null {
      [$"cannot read OTP version from ($loc)"]
    } else if not (numeric $i.otp) {
      [$"image ($loc) OTP ($i.otp) not numeric"]
    } else {
      version-reasons $"image ($loc) OTP ($i.otp)" $i.otp $floor $pin $pin_ok
    }
  } | flatten)
  let reasons = ($pin_reasons | append $runtime_reasons | append $image_reasons)
  {pass: ($reasons | is-empty), reasons: $reasons}
}

def main [--floor: string, --root: path, --image-file: string] {
  let floor = ($floor | default $otp_floor)
  let root = ($root | default $repo | path expand)

  let mise_file = ($root | path join "mise.toml")
  let mise_missing = not ($mise_file | path exists)
  let pin = if $mise_missing { null } else { try { erlang-pin (open $mise_file) } catch { null } }

  let files = if $image_file != null {
    $image_file | split row "," | each {|f| $f | str trim } | where {|f| $f != "" } | each {|f|
      {name: $f, path: (if ($f | str starts-with "/") { $f } else { $root | path join $f })}
    }
  } else {
    ls $root | where type == file | get name | path basename
      | where {|n| $n =~ '^(Dockerfile|Containerfile)(\..+)?$' } | sort
      | each {|n| {name: $n, path: ($root | path join $n)} }
  }
  let missing_files = ($files | where {|f| not ($f.path | path exists) } | each {|f| $"image file not found: ($f.name)" })
  let images = ($files | where {|f| $f.path | path exists } | each {|f| image-otps $f.name (open --raw $f.path) } | flatten)

  let erl = (try {
    do { cd $root; ^erl -noshell -eval $erl_eval } | complete
  } catch {|e|
    {exit_code: 127, stdout: "", stderr: $e.msg}
  })
  let runtime = if $erl.exit_code == 0 and ($erl.stdout | str trim) != "" { otp-version-from-file $erl.stdout } else { null }
  let erl_reasons = if $runtime == null { [$"erl failed \(exit ($erl.exit_code)\): ($erl.stderr | str trim)"] } else { [] }
  let mise_reasons = if $mise_missing { [$"mise.toml not found: ($mise_file)"] } else { [] }

  let verdict = (otp-verdict $floor $pin $runtime $images)
  let reasons = ($mise_reasons | append $verdict.reasons | append $missing_files | append $erl_reasons)
  if ($reasons | is-empty) {
    let shown = if ($images | is-empty) { "none" } else { $images | each {|i| $"($i.file):($i.otp)" } | str join "," }
    print $"PASS audit:otp floor=($floor) pin=($pin) runtime=($runtime) images=($shown)"
  } else {
    print $"FAIL audit:otp ($reasons | str join '; ')"
    exit 1
  }
}
