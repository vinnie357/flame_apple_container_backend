#!/usr/bin/env nu
# test-otp-audit.nu — tests for scripts/otp-audit.nu, the audit:otp gate (#18).
#
# scripts/otp-audit.nu does not exist yet. This whole file is RED (fails to
# parse: module not found) until the implementer adds it. No network and no
# real `erl`: the seam cases use literal text, and the end-to-end cases run the
# script against a fake `erl` on PATH and fixture roots under `mktemp -d`,
# passing --root. Only the `defaults` case runs without --root; it runs the
# script exactly as the audit:otp mise task does
# (`--image-file docs/examples/Dockerfile.flame`) against the real repo files
# with a fake erl that prints the repo's own pin. This repo has no root
# Dockerfile or Containerfile, so plain discovery would find no image; the task
# names the example Dockerfile explicitly. Temp dirs are removed even when an
# assert fails.
#
# Floor: 28.5.0.8. CVE-2026-55953 is fixed in 28.5.0.4, CVE-2026-89422 in
# 28.5.0.7, and CVE-2026-105236 and CVE-2026-94200 in 28.5.0.8.
#
# Interface under test (scripts/otp-audit.nu), FROZEN:
#   const repo = (path self | path dirname | path dirname)
#   const otp_floor = "28.5.0.8"
#   export def version-below [a: string, b: string]: nothing -> bool
#       Split on ".", `into int` per component, pad the shorter with 0,
#       compare left to right. Raises on any non-numeric component ("",
#       "latest", "28.5.0.8-rc1"), in either argument.
#   export def erlang-pin [mise_toml: record]
#       tools.erlang as a string: a string value as is, a record's `version`.
#       null when tools or tools.erlang is missing, and when the value is a
#       list (a list-valued pin FAILs) or any other non-string shape.
#   export def otp-version-from-file [text: string]: nothing -> string
#       First whitespace-separated token of the trimmed text
#       ("28.5.0.8 **\n" -> "28.5.0.8").
#   export def image-otps [file: string, text: string]: nothing -> list<record<file: string, line: int, image: string, otp: any>>
#       One record per Erlang-bearing FROM line, in file order. `line` is
#       1-based; `image` is the image reference token as written; `otp` is a
#       string or null (null = cannot read the OTP version, which FAILs).
#       - Only lines matching `^\s*FROM\s+` (case-insensitive) count; a `#`
#         comment or `RUN echo FROM ...` is never parsed.
#       - `--platform=<v>` is skipped. ` AS <stage>` is dropped.
#       - An `@sha256:...` digest is stripped before parsing the tag.
#       - Repo normalisation: drop a leading registry host (first path
#         component containing `.` or `:`, or equal to `localhost`), then a
#         leading `library/`.
#       - Erlang-bearing = trailing path `hexpm/elixir` or `hexpm/erlang`, or
#         last path component exactly `elixir` or `erlang`.
#           hexpm/elixir:<x>-erlang-<otp>-...  -> otp <otp>
#           hexpm/erlang:<otp>-...             -> otp <otp>
#           erlang:<otp>[-...]  (official)      -> otp <otp> (leading numeric dotted part)
#           elixir:<anything> (official, no OTP in tag), erlang:latest, no tag -> null
#       - Any image reference containing `$` is otp null. Resolving it from a
#         preceding `ARG NAME=default` in the same file is OPTIONAL: when the
#         default resolves, the resolved image is parsed as above; when it does
#         not, otp is null. Tests accept both outcomes, never a pass on a
#         vulnerable default.
#       - Stage references (`FROM builder`), `scratch`, and non-Erlang bases
#         (debian, alpine, flame-runner-base:latest, acme/notelixir) give no record.
#       - A text with ZERO FROM lines returns exactly one record with otp
#         null (fail closed). A text whose FROM lines are all non-Erlang
#         returns [] (passes).
#   export def otp-verdict [floor: string, pin, runtime, images: list]: nothing -> record<pass: bool, reasons: list<string>>
#       Never raises: a raise from version-below on any item becomes a reason.
#       pass == (reasons is empty). Reason formats (substrings frozen):
#         pin null or non-numeric : `erlang pin missing or not numeric: <pin>`
#         pin below floor         : `pin <pin> below floor <floor>`
#         runtime null            : contains `runtime`
#         runtime non-numeric     : contains `runtime` and the value
#         runtime below floor     : `runtime <rt> below floor <floor>`
#         runtime != pin          : `runtime <rt> differs from pin <pin>`
#         image otp null          : `cannot read OTP version from <file>:<line>`
#         image otp non-numeric   : contains `<file>:<line>`
#         image below floor       : `image <file>:<line> OTP <otp> below floor <floor>`
#         image != pin            : `image <file>:<line> OTP <otp> differs from pin <pin>`
#       Equality is numeric (version-below both ways false), not string:
#       runtime "28.5.0.8.0" equals pin "28.5.0.8". A fuzzy pin ("29",
#       "28.5") never equals a 4-part runtime, so it FAILs.
#   def main [--floor: string, --root: path, --image-file: string]
#       --floor      default otp_floor.
#       --root       default $repo (never the cwd). Base for <root>/mise.toml,
#                    image discovery, and erl's cwd.
#       --image-file FROZEN FORM: one comma-separated string,
#                    e.g. `--image-file "Dockerfile,Containerfile.base"`.
#                    (Not list<string>: nushell flags are not repeatable and a
#                    script-level list flag is awkward from a mise run string.)
#                    Relative entries resolve against --root; absolute entries
#                    are used as is. When given, it REPLACES discovery. A
#                    named file that does not exist FAILs.
#       Discovery (no --image-file): files directly in <root> (not recursive)
#       named Dockerfile, Dockerfile.*, Containerfile, Containerfile.*.
#       Discovered files are named relative to <root> in output and reasons.
#       Runtime: runs `erl -noshell -eval '<eval>'` with cwd = <root>, through
#       `complete`. The eval reads releases/<otp_release>/OTP_VERSION under
#       code:root_dir() and halts 0, or prints the error to stderr and halts 1.
#       Runtime = otp-version-from-file(stdout). Non-zero exit or empty
#       output is a null runtime, and the FAIL line carries erl's stderr.
#       A missing <root>/mise.toml FAILs.
#       Output (stdout), last non-empty line:
#         `PASS audit:otp floor=<floor> pin=<pin> runtime=<rt> images=<f>:<otp>,<f>:<otp>`
#           (`images=none` when no Erlang-bearing image exists), exit 0; or
#         `FAIL audit:otp <reason>; <reason>; ...` listing every reason, exit 1.

use std/assert
use ../scripts/otp-audit.nu *

const root = path self ..
const floor = "28.5.0.8"

def has-line [text: string, needle: string] {
  $text | lines | any {|l| $l | str contains $needle }
}

def last-line [text: string] {
  let ls = ($text | lines | where {|l| ($l | str trim) != "" })
  if ($ls | is-empty) { "" } else { $ls | last }
}

def any-reason [v: record, needle: string] {
  $v.reasons | any {|r| $r | str contains $needle }
}

# try/finally: the temp dir is removed whether the body passes or raises.
def with-temp-dir [body: closure] {
  let dir = (mktemp -d)
  try {
    do $body $dir | ignore
  } catch {|e|
    rm -rf $dir
    # Re-raise with the original rendered error so the failing assert shows.
    error make --unspanned {msg: $"($e.msg)\n($e.rendered)"}
  }
  rm -rf $dir
}

def hex-deb [otp: string] { $"hexpm/elixir:1.19.6-erlang-($otp)-debian-bookworm-20261005-slim" }
def hex-alp [otp: string] { $"hexpm/elixir:1.19.6-erlang-($otp)-alpine-3.24.3" }

# A Dockerfile shaped like the repo's: builder on line 2, debian runtime.
def dockerfile [otp: string] {
  $"# builder\nFROM (hex-deb $otp) AS builder\nRUN mix release\n\nFROM debian:bookworm-20261005-slim\nCOPY --from=builder /app /app\n"
}

# A flame-runner-base shaped Containerfile: builder on line 1, alpine runtime.
def containerfile [otp: string] {
  $"FROM (hex-alp $otp) AS builder\nRUN mix release\nFROM alpine:3.24.3 AS runtime\n"
}

# ---------------------------------------------------------------- seam cases

def version-below-cases [] {
  let table = [
    [a b below];
    ["28.5.0.10" "28.5.0.7" false]
    ["28.5.0.7" "28.5.0.7" false]
    ["28.5.0.6" "28.5.0.7" true]
    ["28.5" "28.5.0.7" true]
    ["28.3.2" "28.5.0.7" true]
    ["28.10.0.1" "28.5.0.7" false]
    ["29" "28.5.0.7" false]
    ["27.3.4.17" "28.5.0.7" true]
    ["28.5.0.7" "28.5.0.8" true]
  ]
  for r in $table {
    assert equal (version-below $r.a $r.b) $r.below $"version-below ($r.a) ($r.b) must be ($r.below)"
  }
  assert equal (version-below "28.5.0.8" "28.5.0.8.0") false "padding: 28.5.0.8 is not below 28.5.0.8.0"
  assert equal (version-below "28.5.0.8.0" "28.5.0.8") false "padding: 28.5.0.8.0 is not below 28.5.0.8"
  for bad in ["28.5.0.8-rc1" "latest" ""] {
    let raised = (try { version-below $bad "28.5.0.7" | ignore; false } catch { true })
    assert $raised $"version-below must raise on non-numeric a: '($bad)'"
  }
  let raised = (try { version-below "28.5.0.8" "latest" | ignore; false } catch { true })
  assert $raised "version-below must raise on non-numeric b: 'latest'"
}

def erlang-pin-cases [] {
  assert equal (erlang-pin {tools: {erlang: "28.5.0.8"}}) "28.5.0.8" "a string pin must be returned as is"
  assert equal (erlang-pin {tools: {erlang: {version: "28.5.0.8"}}}) "28.5.0.8" "a {version} record pin must return its version"
  assert equal (erlang-pin {tools: {elixir: "1.19.6-otp-28"}}) null "a missing tools.erlang must be null"
  assert equal (erlang-pin {}) null "a missing [tools] table must be null"
  assert equal (erlang-pin {tools: {erlang: ["28.5.0.8" "27"]}}) null "a list-valued pin must be null (it FAILs)"
  # Parsed from real TOML text, as main reads it.
  assert equal (erlang-pin ("[tools]\nerlang = \"28.5.0.8\"\n" | from toml)) "28.5.0.8" "string pin from TOML text"
  assert equal (erlang-pin ("[tools]\nerlang = { version = \"28.5.0.8\" }\n" | from toml)) "28.5.0.8" "record pin from TOML text"
  assert equal (erlang-pin ("[tools]\nerlang = [\"28.5.0.8\", \"27\"]\n" | from toml)) null "list pin from TOML text must be null"
  let v = (otp-verdict $floor (erlang-pin {tools: {erlang: ["28.5.0.8" "27"]}}) "28.5.0.8" [])
  assert equal $v.pass false "a list-valued pin must FAIL the verdict"
  assert (any-reason $v "erlang pin missing or not numeric") "a list-valued pin must fail as `erlang pin missing or not numeric`"
}

def otp-version-from-file-cases [] {
  assert equal (otp-version-from-file "28.5.0.8\n") "28.5.0.8" "plain OTP_VERSION"
  assert equal (otp-version-from-file "28.5.0.8 **\n") "28.5.0.8" "a patched install writes `28.5.0.8 **`; take the first token"
  assert equal (otp-version-from-file "  28.5.0.8\r\n") "28.5.0.8" "surrounding whitespace is trimmed"
}

def one-otp [file: string, text: string] {
  let r = (image-otps $file $text)
  assert equal ($r | length) 1 $"expected exactly one Erlang image record in: ($text)"
  $r.0
}

def image-otps-cases [] {
  # hexpm/elixir debian, builder line and record fields.
  let r = (image-otps "Dockerfile" (dockerfile "28.5.0.8"))
  assert equal ($r | length) 1 "a multi-stage Dockerfile returns only the builder (debian runtime ignored)"
  assert equal $r.0.file "Dockerfile" "record.file is the file argument"
  assert equal $r.0.line 2 "record.line is the 1-based FROM line"
  assert equal $r.0.image (hex-deb "28.5.0.8") "record.image is the image reference as written (no AS clause)"
  assert equal $r.0.otp "28.5.0.8" "hexpm/elixir debian tag"

  assert equal (one-otp "C" (containerfile "28.5.0.8")).otp "28.5.0.8" "hexpm/elixir alpine tag; alpine runtime ignored"
  assert equal (one-otp "C" (containerfile "28.5.0.8")).line 1 "builder on line 1"
  assert equal (one-otp "C" $"FROM (hex-alp '28.5.0.8') as builder\n").otp "28.5.0.8" "lowercase `as`"
  assert equal (one-otp "C" $"from (hex-alp '28.5.0.8')\n").otp "28.5.0.8" "lowercase `from`"
  assert equal (one-otp "C" $"   FROM (hex-alp '28.5.0.8')\n").otp "28.5.0.8" "leading whitespace before FROM"
  assert equal (one-otp "C" "FROM hexpm/erlang:28.5.0.8-alpine-3.24.3\n").otp "28.5.0.8" "hexpm/erlang tag"
  assert equal (one-otp "C" "FROM hexpm/erlang:28.3.2-alpine-3.24.3 AS b\n").otp "28.3.2" "hexpm/erlang 3-part OTP"

  # --platform, digest, registry, library/, mirror path.
  assert equal (one-otp "C" $"FROM --platform=$BUILDPLATFORM (hex-deb '28.5.0.8') AS builder\n").otp "28.5.0.8" "--platform=$BUILDPLATFORM is skipped (its `$` is not the image)"
  assert equal (one-otp "C" $"FROM --platform=linux/arm64 (hex-deb '28.5.0.8')\n").otp "28.5.0.8" "--platform=linux/arm64 is skipped"
  let digest = ("0123456789abcdef" | fill -c "0" -w 64)
  assert equal (one-otp "C" $"FROM (hex-deb '28.5.0.8')@sha256:($digest) AS builder\n").otp "28.5.0.8" "an @sha256 digest is stripped"
  assert equal (one-otp "C" $"FROM erlang:28.5.0.8@sha256:($digest)\n").otp "28.5.0.8" "an @sha256 digest after an official erlang tag is stripped"
  assert equal (one-otp "C" $"FROM hexpm/elixir@sha256:($digest) AS builder\n").otp null "a digest-only hexpm/elixir reference is Erlang-bearing with no readable OTP (fail closed)"
  assert equal (one-otp "C" $"FROM docker.io/(hex-deb '28.5.0.8') AS builder\n").otp "28.5.0.8" "docker.io/ registry prefix"
  assert equal (one-otp "C" $"FROM registry.example.com:5000/(hex-alp '28.3.2')\n").otp "28.3.2" "registry host with a port"
  assert equal (one-otp "C" $"FROM localhost/(hex-alp '28.3.2')\n").otp "28.3.2" "localhost registry"
  assert equal (one-otp "C" $"FROM localhost:5000/(hex-alp '28.3.2')\n").otp "28.3.2" "localhost:5000 registry"
  assert equal (one-otp "C" $"FROM ghcr.io/acme/(hex-alp '28.3.2')\n").otp "28.3.2" "mirror path ending in hexpm/elixir"
  assert equal (one-otp "C" "FROM docker.io/library/erlang:28.5.0.8-alpine\n").otp "28.5.0.8" "docker.io/library/erlang official tag"
  assert equal (one-otp "C" "FROM library/erlang:28.5.0.8\n").otp "28.5.0.8" "library/erlang official tag"

  # Official images.
  assert equal (one-otp "C" "FROM erlang:28.5.0.8-alpine\n").otp "28.5.0.8" "official erlang:<otp>-alpine"
  assert equal (one-otp "C" "FROM erlang:28.5.0.8-slim AS b\n").otp "28.5.0.8" "official erlang:<otp>-slim"
  assert equal (one-otp "C" "FROM erlang:28.3.2\n").otp "28.3.2" "official erlang:<otp>"
  assert equal (one-otp "C" "FROM erlang:latest\n").otp null "official erlang:latest has no OTP version"
  assert equal (one-otp "C" "FROM elixir:1.19-alpine\n").otp null "official elixir tag has no OTP version"
  assert equal (one-otp "C" "FROM docker.io/library/elixir:1.19.6\n").otp null "registry + library/elixir has no OTP version"
  assert equal (one-otp "C" "FROM elixir\n").otp null "an untagged elixir image has no OTP version"
  assert equal (one-otp "C" "FROM ghcr.io/acme/elixir:1.19.6\n").otp null "a mirror whose last component is elixir is Erlang-bearing"

  # `$` in the image: null (fail closed).
  assert equal (one-otp "C" "FROM ${BUILDER_IMAGE} AS builder\n").otp null "whole-image ${ARG} with no ARG default is null"
  assert equal (one-otp "C" "FROM $BASE\n").otp null "whole-image $ARG with no ARG default is null"
  assert equal (one-otp "C" "FROM --platform=$BUILDPLATFORM ${IMG} AS b\n").otp null "--platform plus a ${ARG} image is null"
  assert equal (one-otp "C" "FROM hexpm/elixir:${ELIXIR}-erlang-${OTP}-alpine-3.24.3\n").otp null "an ${ARG} inside an hexpm tag is null"
  assert equal (one-otp "C" "ARG OTP\nFROM hexpm/elixir:1.19.6-erlang-${OTP}-alpine-3.24.3\n").otp null "an ARG without a default stays null"
  # Optional ARG resolution: either resolved or null, never a pass on a vulnerable default.
  let ok_arg = (one-otp "C" $"ARG BUILDER_IMAGE=(hex-alp '28.5.0.8')\nFROM ${BUILDER_IMAGE} AS builder\n")
  assert ($ok_arg.otp in [null "28.5.0.8"]) $"a resolvable ARG default must resolve to 28.5.0.8 or stay null, got: ($ok_arg.otp)"
  let bad_arg = (one-otp "C" $"ARG BUILDER_IMAGE=(hex-alp '28.3.2')\nFROM ${BUILDER_IMAGE} AS builder\n")
  assert ($bad_arg.otp in [null "28.3.2"]) $"a vulnerable ARG default must resolve to 28.3.2 or stay null, got: ($bad_arg.otp)"
  assert equal (otp-verdict $floor $floor $floor [$bad_arg]).pass false "a vulnerable ARG default must FAIL either way"

  # Comments and non-FROM lines are never parsed.
  let commented = $"# FROM hexpm/elixir:1.19.5-erlang-27.3.4-alpine-3.20.0\nFROM (hex-alp '28.5.0.8') AS builder\n"
  let c = (image-otps "C" $commented)
  assert equal ($c | length) 1 "a `# FROM` comment line is ignored"
  assert equal $c.0.line 2 "only the real FROM line counts"
  assert equal $c.0.otp "28.5.0.8" "the comment's 27.x tag must not be read"
  let run_echo = $"FROM (hex-alp '28.5.0.8') AS builder\nRUN echo FROM hexpm/elixir:1.19.5-erlang-27.3.4-alpine-3.20.0\n"
  assert equal (image-otps "C" $run_echo | length) 1 "FROM inside a RUN line is not a FROM instruction (anchor ^\\s*FROM\\s+)"

  # Stage references, scratch and non-Erlang bases give no record.
  let multi = $"FROM (hex-alp '28.5.0.8') AS builder\nRUN x\nFROM builder AS test\nFROM scratch\nFROM alpine:3.24.3\nFROM debian:bookworm-20261005-slim\nFROM flame-runner-base:latest\nFROM acme/notelixir:1.0\nFROM acme/elixir-tools:1.0\n"
  let m = (image-otps "C" $multi)
  assert equal ($m | length) 1 $"only the hexpm builder is Erlang-bearing in a multi-stage file, got: ($m | to nuon)"
  assert equal $m.0.line 1 "the builder record keeps its line"
  assert equal (image-otps "Containerfile.flame-runner-claude" "FROM flame-runner-base:latest\nRUN x\n") [] "a file whose FROM lines are all non-Erlang returns []"

  # Two Erlang FROM lines: both, in order.
  let two = (image-otps "C" $"FROM (hex-alp '28.5.0.8') AS a\nFROM hexpm/erlang:28.3.2-alpine-3.24.3 AS b\n")
  assert equal ($two | get otp) ["28.5.0.8" "28.3.2"] "every Erlang FROM line yields a record, in file order"
  assert equal ($two | get line) [1 2] "lines in file order"

  # Zero FROM lines: fail closed.
  for t in ["" "RUN echo hi\n" "# FROM hexpm/elixir:1.19.6-erlang-28.5.0.8-alpine-3.24.3\n"] {
    let z = (image-otps "Containerfile.empty" $t)
    assert equal ($z | length) 1 $"a file with zero FROM lines must return exactly one record: '($t)'"
    assert equal $z.0.otp null $"a file with zero FROM lines must have otp null: '($t)'"
    assert equal $z.0.file "Containerfile.empty" "the zero-FROM record names the file"
    let v = (otp-verdict $floor $floor $floor $z)
    assert equal $v.pass false $"a file with zero FROM lines must FAIL: '($t)'"
    assert (any-reason $v "Containerfile.empty") "the zero-FROM reason must name the file"
  }
}

def img [otp, line: int = 2, file: string = "Dockerfile"] {
  {file: $file, line: $line, image: "fixture", otp: $otp}
}

def otp-verdict-cases [] {
  let ok = (otp-verdict $floor "28.5.0.8" "28.5.0.8" [(img "28.5.0.8") (img "28.5.0.8" 1 "Containerfile.base")])
  assert equal $ok {pass: true, reasons: []} "all equal and at the floor must pass with no reasons"
  assert equal (otp-verdict $floor "28.5.0.8" "28.5.0.8" []) {pass: true, reasons: []} "no images must pass"
  assert equal (otp-verdict $floor "28.5.0.9" "28.5.0.9" [(img "28.5.0.9")]).pass true "above the floor and equal must pass"
  assert equal (otp-verdict $floor "28.5.0.8" "28.5.0.8.0" [(img "28.5.0.8.0")]).pass true "equality is numeric: 28.5.0.8.0 equals 28.5.0.8"

  # pin
  let v = (otp-verdict $floor null "28.5.0.8" [])
  assert equal $v.pass false "a null pin must fail"
  assert (any-reason $v "erlang pin missing or not numeric") "null pin reason"
  let v = (otp-verdict $floor "latest" "28.5.0.8" [(img "28.5.0.8")])
  assert equal $v.pass false "a non-numeric pin must fail (and not raise)"
  assert (any-reason $v "erlang pin missing or not numeric: latest") "non-numeric pin reason names the value"
  let v = (otp-verdict $floor "28.3.2" "28.3.2" [])
  assert equal $v.pass false "a pin below the floor must fail"
  assert (any-reason $v "pin 28.3.2 below floor 28.5.0.8") "pin-below reason"
  let v = (otp-verdict $floor "28.5" "28.5.0.8" [])
  assert equal $v.pass false "a fuzzy pin 28.5 must fail"
  let v = (otp-verdict $floor "29" "28.5.0.8" [])
  assert equal $v.pass false "a fuzzy pin 29 must fail: it never equals a 4-part runtime"
  assert (any-reason $v "runtime 28.5.0.8 differs from pin 29") "fuzzy pin 29 fails as runtime differs from pin"

  # runtime
  let v = (otp-verdict $floor "28.5.0.8" null [])
  assert equal $v.pass false "a null runtime must fail"
  assert (any-reason $v "runtime") "null runtime reason mentions runtime"
  let v = (otp-verdict $floor "28.5.0.8" "garbage" [])
  assert equal $v.pass false "a non-numeric runtime must fail (and not raise)"
  assert ($v.reasons | any {|r| ($r | str contains "runtime") and ($r | str contains "garbage") }) "non-numeric runtime reason names runtime and the value"
  let v = (otp-verdict $floor "28.5.0.8" "28.5.0.7" [])
  assert equal $v.pass false "a runtime below the floor must fail"
  assert (any-reason $v "runtime 28.5.0.7 below floor 28.5.0.8") "runtime-below reason"
  assert (any-reason $v "runtime 28.5.0.7 differs from pin 28.5.0.8") "a runtime below the pin also differs from it"
  let v = (otp-verdict $floor "28.5.0.8" "28.5.0.9" [])
  assert equal $v.pass false "a runtime above the floor that differs from the pin must fail"
  assert (any-reason $v "runtime 28.5.0.9 differs from pin 28.5.0.8") "runtime-differs reason"
  assert (not (any-reason $v "below floor")) "a runtime above the floor must not report below floor"

  # images
  let v = (otp-verdict $floor "28.5.0.8" "28.5.0.8" [(img null 3)])
  assert equal $v.pass false "an unparseable image must fail"
  assert (any-reason $v "cannot read OTP version from Dockerfile:3") "unparseable-image reason"
  let v = (otp-verdict $floor "28.5.0.8" "28.5.0.8" [(img "x.y" 3)])
  assert equal $v.pass false "a non-numeric image otp must fail (and not raise)"
  assert (any-reason $v "Dockerfile:3") "non-numeric image reason names file:line"
  let v = (otp-verdict $floor "28.5.0.8" "28.5.0.8" [(img "28.5.0.4" 7)])
  assert equal $v.pass false "an image below the floor must fail"
  assert (any-reason $v "image Dockerfile:7 OTP 28.5.0.4 below floor 28.5.0.8") "image-below reason"
  assert (any-reason $v "image Dockerfile:7 OTP 28.5.0.4 differs from pin 28.5.0.8") "an image below the pin also differs from it"
  let v = (otp-verdict $floor "28.5.0.8" "28.5.0.8" [(img "28.5.0.9" 1 "Containerfile.base")])
  assert equal $v.pass false "an image above the floor that differs from the pin must fail"
  assert (any-reason $v "image Containerfile.base:1 OTP 28.5.0.9 differs from pin 28.5.0.8") "image-differs reason"
  let v = (otp-verdict $floor null "28.5.0.8" [(img "28.5.0.8")])
  assert equal $v.pass false "an image with a null pin must not raise and must fail"

  # several reasons together
  let v = (otp-verdict $floor "28.5.0.8" "28.5.0.9" [(img null 3) (img "28.5.0.4" 5 "Containerfile.base")])
  assert equal $v.pass false "several failures must fail"
  assert (any-reason $v "runtime 28.5.0.9 differs from pin 28.5.0.8") "several: runtime reason"
  assert (any-reason $v "cannot read OTP version from Dockerfile:3") "several: unparseable reason"
  assert (any-reason $v "image Containerfile.base:5 OTP 28.5.0.4 below floor 28.5.0.8") "several: image-below reason"
  assert (($v.reasons | length) >= 3) $"every reason must be listed, got: ($v.reasons)"
  let v = (otp-verdict $floor "28.3.2" "28.3.2" [(img "28.3.2")])
  assert (any-reason $v "pin 28.3.2 below floor") "main-shaped: pin"
  assert (any-reason $v "runtime 28.3.2 below floor") "main-shaped: runtime"
  assert (any-reason $v "image Dockerfile:2 OTP 28.3.2 below floor") "main-shaped: image"
  assert equal (otp-verdict "28.5.0.9" "28.5.0.8" "28.5.0.8" [(img "28.5.0.8")]).pass false "the floor argument is honoured"
}

# ---------------------------------------------------------- end-to-end cases

def mise-toml [pin: string] { $"[tools]\nerlang = \"($pin)\"\nelixir = \"1.19.6-otp-28\"\n" }

# Fixture root: <base>/<name> with an optional mise.toml text and files.
def fixture [base: string, name: string, mise, files: record] {
  let r = ($base | path join $name)
  mkdir $r
  if $mise != null { $mise | save ($r | path join "mise.toml") }
  for f in ($files | transpose name text) {
    let p = ($r | path join $f.name)
    mkdir ($p | path dirname)
    $f.text | save $p
  }
  $r
}

def images-of [line: string] {
  let hit = ($line | parse --regex 'images=(?<i>\S+)$')
  if ($hit | is-empty) { [] } else { $hit.0.i | split row "," | sort }
}

def end-to-end-cases [] {
  with-temp-dir {|dir|
    let bin = ($dir | path join "bin")
    let work = ($dir | path join "cwd")
    mkdir $bin $work
    let script = ($root | path join "scripts" "otp-audit.nu")
    let nu_exe = $nu.current-exe

    # Fake erl: records its args and physical cwd, prints FAKE_OTP, or prints
    # FAKE_ERL_STDERR to stderr and exits FAKE_ERL_EXIT.
    let erl = ($bin | path join "erl")
    [
      "#!/bin/sh"
      $"D='($dir)'"
      "pwd -P > \"$D/erl-cwd\""
      "printf '%s\\n' \"$@\" > \"$D/erl-args\""
      "if [ -n \"$FAKE_ERL_EXIT\" ]; then printf '%s\\n' \"$FAKE_ERL_STDERR\" >&2; exit \"$FAKE_ERL_EXIT\"; fi"
      "printf '%s\\n' \"$FAKE_OTP\""
      "exit 0"
    ] | str join "\n" | save $erl
    ^chmod +x $erl
    let path = ($env.PATH | prepend $bin)

    let run = {|flags: list, fake: record|
      rm -f ($dir | path join "erl-cwd") ($dir | path join "erl-args")
      let r = (do {
        hide-env -i FAKE_OTP FAKE_ERL_EXIT FAKE_ERL_STDERR
        # cwd is an unrelated temp dir, so a cwd-relative default fails.
        cd $work
        with-env ({PATH: $path} | merge $fake) { ^$nu_exe -n $script ...$flags }
      } | complete)
      let cwd_file = ($dir | path join "erl-cwd")
      let args_file = ($dir | path join "erl-args")
      $r | merge {
        last: (last-line $r.stdout)
        erl_cwd: (if ($cwd_file | path exists) { open --raw $cwd_file | str trim } else { null })
        erl_args: (if ($args_file | path exists) { open --raw $args_file } else { "" })
      }
    }
    let ok8 = {FAKE_OTP: "28.5.0.8"}

    let assert_fail = {|r: record, label: string, needles: list|
      assert ($r.exit_code != 0) $"($label): must exit non-zero; stdout: ($r.stdout) stderr: ($r.stderr)"
      assert ($r.last | str starts-with "FAIL audit:otp ") $"($label): last line must start with `FAIL audit:otp `; got: ($r.last) stderr: ($r.stderr)"
      for n in $needles {
        assert ($r.last | str contains $n) $"($label): FAIL line must contain `($n)`; got: ($r.last)"
      }
    }

    # ---- PASS: repo-shaped fixture, all at 28.5.0.8, plus a non-Erlang Containerfile and a nested file.
    let pass_root = (fixture $dir "pass" (mise-toml "28.5.0.8") {
      Dockerfile: (dockerfile "28.5.0.8")
      "Containerfile.flame-runner-base": (containerfile "28.5.0.8")
      "Containerfile.flame-runner-claude": "FROM flame-runner-base:latest\nRUN x\n"
      "nested/Dockerfile": (dockerfile "27.3.4")
      "README.md": "FROM hexpm/elixir:1.19.5-erlang-27.3.4-alpine-3.20.0\n"
    })
    let r = (do $run ["--root" $pass_root] $ok8)
    assert equal $r.exit_code 0 $"pass fixture must exit 0; stdout: ($r.stdout) stderr: ($r.stderr)"
    assert ($r.last | str starts-with "PASS audit:otp floor=28.5.0.8 pin=28.5.0.8 runtime=28.5.0.8 images=") $"PASS line shape; got: ($r.last)"
    assert equal (images-of $r.last) ["Containerfile.flame-runner-base:28.5.0.8" "Dockerfile:28.5.0.8"] $"PASS images list: discovered root files named relative to --root, not recursive; got: ($r.last)"
    assert equal $r.erl_cwd ($pass_root | path expand) "erl must run with cwd = --root"
    assert ($r.erl_args | str contains "-noshell") "erl must be called with -noshell"
    assert ($r.erl_args | str contains "-eval") "erl must be called with -eval"
    assert ($r.erl_args | str contains "OTP_VERSION") "the eval must read OTP_VERSION"
    assert ($r.erl_args | str contains "halt(1)") "the eval must halt(1) on a read error"

    # Patched-install OTP_VERSION form.
    let r = (do $run ["--root" $pass_root] {FAKE_OTP: "28.5.0.8 **"})
    assert equal $r.exit_code 0 $"`28.5.0.8 **` must read as 28.5.0.8; stdout: ($r.stdout)"

    # images=none
    let none_root = (fixture $dir "none" (mise-toml "28.5.0.8") {"Containerfile.app": "FROM alpine:3.24.3\n"})
    let r = (do $run ["--root" $none_root] $ok8)
    assert equal $r.exit_code 0 $"a root with no Erlang images must pass; stdout: ($r.stdout) stderr: ($r.stderr)"
    assert equal $r.last "PASS audit:otp floor=28.5.0.8 pin=28.5.0.8 runtime=28.5.0.8 images=none" "no Erlang images prints images=none"
    let empty_root = (fixture $dir "empty" (mise-toml "28.5.0.8") {})
    let r = (do $run ["--root" $empty_root] $ok8)
    assert equal $r.last "PASS audit:otp floor=28.5.0.8 pin=28.5.0.8 runtime=28.5.0.8 images=none" "no image files prints images=none"

    # Record pin.
    let rec_root = (fixture $dir "rec" "[tools]\nerlang = { version = \"28.5.0.8\" }\n" {Dockerfile: (dockerfile "28.5.0.8")})
    let r = (do $run ["--root" $rec_root] $ok8)
    assert equal $r.exit_code 0 $"a {version} record pin must pass; stdout: ($r.stdout) stderr: ($r.stderr)"

    # ---- FAIL reasons.
    # main's pre-bump files: pin, runtime and image all 28.3.2.
    let old_root = (fixture $dir "old" (mise-toml "28.3.2") {Dockerfile: (dockerfile "28.3.2"), "Containerfile.flame-runner-base": (containerfile "28.3.3")})
    let r = (do $run ["--root" $old_root] {FAKE_OTP: "28.3.2"})
    do $assert_fail $r "pre-bump files" ["pin 28.3.2 below floor 28.5.0.8" "runtime 28.3.2 below floor 28.5.0.8" "image Dockerfile:2 OTP 28.3.2 below floor 28.5.0.8" "image Containerfile.flame-runner-base:1 OTP 28.3.3 below floor 28.5.0.8" "; "]

    let r = (do $run ["--root" $pass_root] {FAKE_OTP: "28.5.0.9"})
    do $assert_fail $r "runtime differs" ["runtime 28.5.0.9 differs from pin 28.5.0.8"]
    let r = (do $run ["--root" $pass_root] {FAKE_OTP: "28.5.0.7"})
    do $assert_fail $r "runtime below" ["runtime 28.5.0.7 below floor 28.5.0.8"]

    let r = (do $run ["--root" (fixture $dir "img-diff" (mise-toml "28.5.0.8") {Dockerfile: (dockerfile "28.5.0.9")})] $ok8)
    do $assert_fail $r "image differs" ["image Dockerfile:2 OTP 28.5.0.9 differs from pin 28.5.0.8"]
    let r = (do $run ["--root" (fixture $dir "img-below" (mise-toml "28.5.0.8") {"Containerfile.x": (containerfile "28.5.0.4")})] $ok8)
    do $assert_fail $r "image below" ["image Containerfile.x:1 OTP 28.5.0.4 below floor 28.5.0.8"]
    let r = (do $run ["--root" (fixture $dir "official" (mise-toml "28.5.0.8") {Dockerfile: "FROM elixir:1.19-alpine AS builder\n"})] $ok8)
    do $assert_fail $r "official elixir tag" ["cannot read OTP version from Dockerfile:1"]
    let r = (do $run ["--root" (fixture $dir "arg" (mise-toml "28.5.0.8") {Dockerfile: "FROM ${BUILDER_IMAGE} AS builder\nFROM debian:bookworm-20261005-slim\n"})] $ok8)
    do $assert_fail $r "whole-image ARG" ["cannot read OTP version from Dockerfile:1"]
    let r = (do $run ["--root" (fixture $dir "registry" (mise-toml "28.5.0.8") {Dockerfile: $"FROM docker.io/(hex-deb '28.3.2') AS builder\n"})] $ok8)
    do $assert_fail $r "registry-prefixed vulnerable image" ["image Dockerfile:1 OTP 28.3.2 below floor 28.5.0.8"]
    let r = (do $run ["--root" (fixture $dir "zero" (mise-toml "28.5.0.8") {Dockerfile: (dockerfile "28.5.0.8"), "Containerfile.empty": "# nothing here\n"})] $ok8)
    do $assert_fail $r "zero FROM lines" ["Containerfile.empty"]
    let r = (do $run ["--root" (fixture $dir "dockerfile-dot" (mise-toml "28.5.0.8") {"Dockerfile.dev": (dockerfile "28.3.2")})] $ok8)
    do $assert_fail $r "Dockerfile.* discovery" ["image Dockerfile.dev:2 OTP 28.3.2 below floor 28.5.0.8"]
    let r = (do $run ["--root" (fixture $dir "containerfile-bare" (mise-toml "28.5.0.8") {"Containerfile": (containerfile "28.3.2")})] $ok8)
    do $assert_fail $r "Containerfile discovery" ["image Containerfile:1 OTP 28.3.2 below floor 28.5.0.8"]

    let r = (do $run ["--root" (fixture $dir "nopin" "[tools]\nelixir = \"1.19.6-otp-28\"\n" {})] $ok8)
    do $assert_fail $r "missing pin" ["erlang pin missing or not numeric"]
    let r = (do $run ["--root" (fixture $dir "listpin" "[tools]\nerlang = [\"28.5.0.8\", \"27\"]\n" {})] $ok8)
    do $assert_fail $r "list pin" ["erlang pin missing or not numeric"]
    let r = (do $run ["--root" (fixture $dir "latestpin" (mise-toml "latest") {})] $ok8)
    do $assert_fail $r "latest pin" ["erlang pin missing or not numeric: latest"]
    let r = (do $run ["--root" (fixture $dir "nomise" null {Dockerfile: (dockerfile "28.5.0.8")})] $ok8)
    do $assert_fail $r "missing mise.toml" []

    # Fake erl failing: exit 1 with stderr; the FAIL reason carries the stderr.
    let r = (do $run ["--root" $pass_root] {FAKE_ERL_EXIT: "1", FAKE_ERL_STDERR: "{error,enoent_fixture_marker}"})
    do $assert_fail $r "erl exit 1" ["runtime" "enoent_fixture_marker"]
    let r = (do $run ["--root" $pass_root] {FAKE_OTP: ""})
    do $assert_fail $r "erl empty output" ["runtime"]

    # --floor is honoured (negative control) and the default floor is 28.5.0.8.
    let r = (do $run ["--root" $pass_root "--floor" "28.5.0.9"] $ok8)
    do $assert_fail $r "--floor 28.5.0.9" ["pin 28.5.0.8 below floor 28.5.0.9" "runtime 28.5.0.8 below floor 28.5.0.9" "image Dockerfile:2 OTP 28.5.0.8 below floor 28.5.0.9"]
    let r = (do $run ["--root" $pass_root "--floor" "28.5.0.4"] $ok8)
    assert ($r.last | str starts-with "PASS audit:otp floor=28.5.0.4 ") $"--floor appears in the PASS line; got: ($r.last)"
    let r7 = (fixture $dir "floor7" (mise-toml "28.5.0.7") {Dockerfile: (dockerfile "28.5.0.7")})
    let r = (do $run ["--root" $r7] {FAKE_OTP: "28.5.0.7"})
    do $assert_fail $r "default floor rejects 28.5.0.7" ["pin 28.5.0.7 below floor 28.5.0.8" "runtime 28.5.0.7 below floor 28.5.0.8" "image Dockerfile:2 OTP 28.5.0.7 below floor 28.5.0.8"]
    let r = (do $run ["--root" $pass_root] $ok8)
    assert equal $r.exit_code 0 "default floor accepts 28.5.0.8"
    assert ($r.last | str starts-with "PASS audit:otp floor=28.5.0.8 ") $"the default floor is 28.5.0.8; got: ($r.last)"

    # --image-file: comma-separated, replaces discovery, relative to --root or absolute.
    let ovr_root = (fixture $dir "override" (mise-toml "28.5.0.8") {
      Dockerfile: (dockerfile "28.5.0.8")
      "Containerfile.base": (containerfile "28.5.0.8")
      "Dockerfile.bad": (dockerfile "28.3.2")
      "sub/Containerfile.extra": (containerfile "28.3.2")
    })
    let r = (do $run ["--root" $ovr_root] $ok8)
    do $assert_fail $r "discovery sees Dockerfile.bad" ["Dockerfile.bad:2"]
    let r = (do $run ["--root" $ovr_root "--image-file" "Dockerfile,Containerfile.base"] $ok8)
    assert equal $r.exit_code 0 $"--image-file must replace discovery, Dockerfile.bad excluded; stdout: ($r.stdout) stderr: ($r.stderr)"
    assert equal (images-of $r.last) ["Containerfile.base:28.5.0.8" "Dockerfile:28.5.0.8"] $"--image-file entries are listed as given; got: ($r.last)"
    let r = (do $run ["--root" $ovr_root "--image-file" "Dockerfile,sub/Containerfile.extra"] $ok8)
    do $assert_fail $r "--image-file relative to --root" ["sub/Containerfile.extra:1 OTP 28.3.2 below floor 28.5.0.8"]
    let abs = ($ovr_root | path join "Dockerfile.bad")
    let r = (do $run ["--root" $ovr_root "--image-file" $abs] $ok8)
    do $assert_fail $r "--image-file absolute" ["Dockerfile.bad:2 OTP 28.3.2 below floor 28.5.0.8"]
    let r = (do $run ["--root" $ovr_root "--image-file" "Dockerfile,no-such-Containerfile"] $ok8)
    do $assert_fail $r "--image-file missing file" ["no-such-Containerfile"]

    # --image-file at a nested relative path, holding this repo's pre-bump
    # builder: the official elixir tag carries no OTP version, so it FAILs.
    let nested_root = (fixture $dir "nested-flame" (mise-toml "28.5.0.8") {
      "docs/examples/Dockerfile.flame": "# builder\nFROM elixir:1.18-alpine AS builder\nRUN mix release\n\nFROM alpine:3.21\n"
    })
    let r = (do $run ["--root" $nested_root "--image-file" "docs/examples/Dockerfile.flame"] $ok8)
    do $assert_fail $r "--image-file nested official elixir" ["cannot read OTP version from docs/examples/Dockerfile.flame:2"]

    # ---- defaults: no --root, no --floor; the exact audit:otp invocation
    # (`--image-file docs/examples/Dockerfile.flame`) against the real repo
    # files; fake erl prints the repo's own pin. Proves the default root, the
    # task's image file and that the bump itself is green.
    let repo_pin = (erlang-pin (open ($root | path join "mise.toml")))
    assert ($repo_pin != null) "the repo mise.toml must pin erlang"
    let r = (do $run ["--image-file" "docs/examples/Dockerfile.flame"] {FAKE_OTP: $repo_pin})
    assert equal $r.exit_code 0 $"defaults against the real repo must pass; stdout: ($r.stdout) stderr: ($r.stderr)"
    assert ($r.last | str starts-with $"PASS audit:otp floor=($floor) pin=($floor) runtime=($floor) images=docs/examples/Dockerfile.flame:($floor)") $"defaults PASS line: pin, runtime and docs/examples/Dockerfile.flame all at ($floor); got: ($r.last)"
    assert equal $r.erl_cwd ($root | path expand) "with no --root, erl must run with cwd = the repo root, not the caller's cwd"
  }
}

def main [] {
  version-below-cases
  erlang-pin-cases
  otp-version-from-file-cases
  image-otps-cases
  otp-verdict-cases
  end-to-end-cases
  print "PASS test:otp-audit"
}
