#!/usr/bin/env nu
# test-audit-wiring.nu — T2-T7: audit gate wiring, allow-list parity, the STRIDE doc,
# the OTP floor wiring and the Dependabot config.
#
# Reads files only; evaluates nothing. Each section runs even when an earlier
# one fails, so one run reports every red section. Exits 1 on any failure.
#
# T2 wiring:
#   - mise.toml [tasks."audit:deps"] runs `nu scripts/deps-audit.nu` and has
#     `depends = ["audit:hex"]`.
#   - [tasks."audit:hex"].depends contains "deps" (the `mix deps.get` task),
#     so the audit never runs against an unfetched dependency tree.
#   - tasks.ci.depends contains audit:hex, audit:deps, audit:advisory-doc,
#     test:deps-audit, test:hex-audit-offline, test:audit-wiring and
#     test:advisory-doc (membership only: mise runs depends in parallel, so
#     order means nothing). Each task runs its file.
#   - mix.exs declares :mix_audit with `only: [:dev, :test]` and `runtime: false`.
#   - .mix-audit-ignore exists at the repo root; .mix-audit-skips does not
#     (guards the earlier name, so every repo uses one file name).
#   - The positive-control lock's "bandit" entry has the real lock's 8-element
#     shape. A lock mix_audit cannot evaluate reads as 0 deps and passes, so a
#     control held to the real shape proves mix_audit parses that shape.
# T3 allow-list parity:
#   - IDs in mix.exs `hex: [ignore_advisories: ...]` equal the ID lines of
#     .mix-audit-ignore.
#   - Each ID sits directly under `# <ID> https://github.com/vinnie357/flame_apple_container_backend/issues/<N> docs/security/advisory-exceptions.md#<lower ID>`
#     in both files, with the same <N>.
#   - .mix-audit-ignore lines carry no leading or trailing whitespace
#     (mix_audit does not trim, so a stray space turns a comment into an ID or
#     makes an ID unmatchable).
#   - A known CVE with a GHSA alias appears only in its GHSA form.
# T4 doc parity (docs/security/advisory-exceptions.md):
#   - every allow-list ID has a `## <ID>` section with the 14 `###`
#     subsections in order;
#   - `### Tracking` names the same issue number as the T3 comments;
#   - `### Owner` is non-empty;
#   - `### Review trigger` has exactly one `Reviewed: YYYY-MM-DD` and one
#     `Next review: YYYY-MM-DD` line; both are valid dates, Next review is
#     later than Reviewed, and Next review is at most 90 days after Reviewed
#     (clock-free; fixtures pin 90 days as the limit and 91 days as a failure).
#   The overdue check against today lives in
#   scripts/advisory-doc.nu, task audit:advisory-doc; see test/test-advisory-doc.nu.
#   The doc is one living record: a review overwrites Reviewed, Next review and
#   the analysis in place, and git history keeps past reviews. Nothing here
#   requires keeping old reviews.
# T5 no orphans: every `## <ID>` section in the doc is on both allow-lists.
# T6 otp wiring (#18). Fails, never skips, when a target is missing:
#   - mise.toml [tasks."audit:otp"] runs exactly
#     `nu scripts/otp-audit.nu --image-file docs/examples/Dockerfile.flame` (no
#     --floor override; this repo has no root Dockerfile, so the task names the
#     example Dockerfile) and [tasks."test:otp-audit"] runs exactly
#     `nu test/test-otp-audit.nu`; both are in tasks.ci.depends.
#   - scripts/otp-audit.nu exists and has exactly one `const otp_floor` line,
#     and it is exactly `const otp_floor = "28.5.0.8"` (raising the floor is a
#     deliberate test change). The E2E default-floor pair in
#     test/test-otp-audit.nu proves the const is the enforced default.
#   - mise.toml pins tools.erlang == "28.5.0.8" and
#     tools.elixir == "1.19.6-otp-28".
#   - docs/examples/Dockerfile.flame: the first FROM is
#     `hexpm/elixir:1.19.6-erlang-28.5.0.8-alpine-3.24.3 AS builder`, and the
#     runtime FROM is `alpine:3.24.3`, the builder tag's alpine version.
# T7 dependabot (#18). Fails, never skips, when the file is missing:
#   - .github/dependabot.yml parses, `version` == 2.
#   - exactly one `mix` entry, at ["/"] (`directory: "/"` or
#     `directories: ["/"]`).
#   - exactly one `github-actions` entry at ["/"].
#   - both have schedule.interval == "weekly".
#   - no directory value contains `*`: a glob such as `/**` would pick up the
#     deliberately vulnerable positive-control fixture lock
#     (test/fixtures/deps_audit/positive_control/mix.lock) and blind audit:deps.
#
# Doc sections: only `## ` headings outside fenced code blocks whose text
# matches the advisory ID shape `^[A-Z][A-Z0-9]*(-[A-Za-z0-9]+)+$` start a
# section, so policy headings (`## Rule`, `## Template`, `## Exceptions`) and a
# fenced template `## <ID>` are not sections. Fenced lines inside an ID section
# are dropped. The clock-free, file-free "T5 fixture: doc-sections" entry pins
# this on fixture text.

use std/assert

const root = path self ..

const subsections = [
  "Advisory"
  "Exposure"
  "Spoofing"
  "Tampering"
  "Repudiation"
  "Information disclosure"
  "Denial of service"
  "Elevation of privilege"
  "Likelihood and impact"
  "Existing mitigations"
  "Residual risk"
  "Review trigger"
  "Owner"
  "Tracking"
]

# Known CVE -> GHSA alias pairs; the CVE form must not appear on either list.
const aliases = [
  {cve: "CVE-2026-43966", ghsa: "GHSA-w4f7-4cxr-rv3c"}
]

const doc_path = "docs/security/advisory-exceptions.md"

const max_review_gap_days = 90

# Parsed YYYY-MM-DD, or null when it is not a valid date.
def parse-day [text: string] {
  if not ($text =~ '^\d{4}-\d{2}-\d{2}$') { return null }
  try { $text | into datetime --format "%Y-%m-%d" } catch { null }
}

# true when Next review is after Reviewed and at most 90 days after it.
def review-gap-ok [reviewed: string, next_review: string] {
  let r = (parse-day $reviewed)
  let n = (parse-day $next_review)
  if ($r == null) or ($n == null) { return false }
  # Rounded: local dates across a DST change differ by a fractional day.
  let days = (($n - $r) / 1day | math round)
  ($days > 0) and ($days <= $max_review_gap_days)
}

def review-gap-fixtures [] {
  assert equal (review-gap-ok "2026-10-19" "2027-01-17") true "90 days after Reviewed is the limit and must pass"
  assert equal (review-gap-ok "2026-10-19" "2027-01-18") false "91 days after Reviewed must fail"
  assert equal (review-gap-ok "2026-10-19" "2026-10-19") false "Next review equal to Reviewed must fail"
  assert equal (review-gap-ok "2026-10-19" "2026-10-18") false "Next review before Reviewed must fail"
  assert equal (review-gap-ok "2026-10-19" "2027-02-30") false "an invalid date must fail"
}

def read [rel: string] {
  open --raw ($root | path join $rel)
}

def comment-pattern [id: string] {
  let anchor = ($id | str downcase)
  $"^# ($id) https://github\\.com/vinnie357/flame_apple_container_backend/issues/\(?<n>\\d+\) docs/security/advisory-exceptions\\.md#($anchor)$"
}

# {id, comment} for each quoted ID in mix.exs hex ignore_advisories.
def mix-exs-entries [] {
  let blocks = (read "mix.exs" | parse --regex '(?s)ignore_advisories:\s*\[(?<body>[^\]]*)\]')
  assert equal ($blocks | length) 1 "mix.exs must have one hex ignore_advisories list"
  let lines = ($blocks.0.body | lines | each {|l| $l | str trim } | where {|l| $l != "" })
  $lines | enumerate | where {|e| $e.item | str starts-with '"' } | each {|e|
    {
      id: ($e.item | parse --regex '^"(?<id>[^"]+)"').0.id
      comment: (if $e.index > 0 { $lines | get ($e.index - 1) } else { "" })
    }
  }
}

# {id, comment} for each ID line in .mix-audit-ignore; [] when the file is
# missing (T2 asserts it exists), so T3-T5 still report their own failures.
def ignore-file-entries [] {
  let file = ($root | path join ".mix-audit-ignore")
  if not ($file | path exists) { return [] }
  let lines = (open --raw $file | lines)
  $lines | enumerate | where {|e| not (($e.item | str starts-with "#") or ($e.item | str trim | is-empty)) } | each {|e|
    {id: $e.item, comment: (if $e.index > 0 { $lines | get ($e.index - 1) } else { "" })}
  }
}

def issue-number [entry: record] {
  let hit = ($entry.comment | parse --regex (comment-pattern $entry.id))
  assert equal ($hit | length) 1 $"comment above ($entry.id) must be `# ($entry.id) https://github.com/vinnie357/flame_apple_container_backend/issues/<N> ($doc_path)#($entry.id | str downcase)`, got: ($entry.comment)"
  $hit.0.n
}

const id_heading_re = '^[A-Z][A-Z0-9]*(-[A-Za-z0-9]+)+$'

# `## <ID>` sections of text, outside fenced code blocks and keyed by an
# ID-shaped heading: {id, subsections: list<{name, body}>}. Fenced lines inside
# an ID section are dropped.
def doc-sections-of [text: string] {
  mut sections = []
  mut current = {id: "", body: []}
  mut fenced = false
  for l in ($text | lines) {
    if ($l | str starts-with "```") { $fenced = not $fenced }
    if (not $fenced) and ($l | str starts-with "## ") {
      if $current.id != "" { $sections = ($sections | append $current) }
      let heading = ($l | str substring 3.. | str trim)
      $current = {id: (if ($heading =~ $id_heading_re) { $heading } else { "" }), body: []}
    } else if (not $fenced) and $current.id != "" {
      $current.body = ($current.body | append $l)
    }
  }
  if $current.id != "" { $sections = ($sections | append $current) }
  $sections | each {|sec|
    let chunk = ($sec.body | str join "\n")
    let subs = ($chunk | split row --regex '(?m)^### ' | skip 1 | each {|s|
      {name: ($s | lines | first | str trim), body: ($s | lines | skip 1 | str join "\n")}
    })
    {id: $sec.id, subsections: $subs}
  }
}

def doc-sections [] {
  doc-sections-of (read $doc_path)
}

# Clock-free and file-free: policy headings and fenced template headings are
# not sections; a real ID heading is.
def doc-sections-fixture [] {
  let fence = "```"
  let policy = ([
    "# Advisory exceptions"
    ""
    "## Rule"
    ""
    "Every allow-listed ID gets a section."
    ""
    "## Template"
    ""
    $"($fence)markdown"
    "## <ID>"
    ""
    "## GHSA-xxxx-xxxx-xxxx"
    ""
    "### Advisory"
    ""
    "Next review: 2000-01-01"
    $fence
    ""
    "## Exceptions"
    ""
    "No exceptions."
  ] | str join "\n")
  assert equal (doc-sections-of $policy | length) 0 $"policy headings and a fenced template must yield 0 sections, got: (doc-sections-of $policy | to nuon)"

  let real = ([
    $policy
    ""
    "## GHSA-aaaa-bbbb-cccc"
    ""
    "### Advisory"
    ""
    "Real advisory text."
    ""
    $"($fence)markdown"
    "### Fenced"
    $fence
    ""
    "### Owner"
    ""
    "Maintainer"
  ] | str join "\n")
  let got = (doc-sections-of $real)
  assert equal ($got | length) 1 $"a real ID heading must yield 1 section, got: ($got | to nuon)"
  assert equal $got.0.id "GHSA-aaaa-bbbb-cccc" "the section id must be the heading text"
  assert equal ($got.0.subsections | get name) ["Advisory" "Owner"] "subsections must be in order, with fenced headings dropped"
  assert (($got.0.subsections | where name == "Owner" | get 0.body) | str contains "Maintainer") "a subsection body must hold its lines"
}

# A mise task's `run` as a list: a string becomes [string]; missing is [].
def run-list [task] {
  let run = ($task | get -o run)
  if $run == null { return [] }
  if ($run | describe | str starts-with "list") { $run } else { [$run] }
}

# A dependabot update entry's directories: `directories`, else [`directory`].
def update-dirs [u: record] {
  let many = ($u | get -o directories)
  let one = ($u | get -o directory)
  if $many != null { $many } else if $one != null { [$one] } else { [] }
}

def t2-wiring [] {
  let tasks = (open ($root | path join "mise.toml") | get tasks)
  let deps_task = ($tasks | get -o "audit:deps")
  assert ($deps_task != null) "mise.toml must define [tasks.\"audit:deps\"]"
  assert equal $deps_task.run "nu scripts/deps-audit.nu" "audit:deps must run nu scripts/deps-audit.nu"
  assert equal ($deps_task | get -o depends) ["audit:hex"] "audit:deps must declare depends = [\"audit:hex\"]"
  let hex_depends = ($tasks | get -o "audit:hex" | get -o depends | default [])
  assert ("deps" in $hex_depends) "audit:hex must declare depends containing \"deps\" (mix deps.get)"

  let ci = $tasks.ci.depends
  for t in ["audit:hex" "audit:deps" "audit:advisory-doc" "test:deps-audit" "test:hex-audit-offline" "test:audit-wiring" "test:advisory-doc"] {
    assert ($t in $ci) $"tasks.ci.depends must include ($t)"
  }
  for pair in [["test:deps-audit" "nu test/test-deps-audit.nu"] ["test:hex-audit-offline" "nu test/test-hex-audit-offline.nu"] ["test:audit-wiring" "nu test/test-audit-wiring.nu"] ["test:advisory-doc" "nu test/test-advisory-doc.nu"] ["audit:advisory-doc" "nu scripts/advisory-doc.nu"]] {
    assert equal ($tasks | get -o $pair.0 | get -o run) $pair.1 $"($pair.0) must run `($pair.1)`"
  }

  let mix_audit = (read "mix.exs" | lines | where {|l| $l =~ '\{:mix_audit,' })
  assert equal ($mix_audit | length) 1 "mix.exs must declare :mix_audit once"
  assert ($mix_audit.0 | str contains "only: [:dev, :test]") "mix_audit must be only: [:dev, :test]"
  assert ($mix_audit.0 | str contains "runtime: false") "mix_audit must be runtime: false"

  assert (($root | path join ".mix-audit-ignore") | path exists) ".mix-audit-ignore must exist at the repo root"
  assert (not (($root | path join ".mix-audit-skips") | path exists)) ".mix-audit-skips must not exist; the one file name is .mix-audit-ignore"

  let shape = '^  "bandit": \{:hex, :bandit, "[^"]+", "[0-9a-f]{64}", \[:mix\], \[.*\], "hexpm", "[0-9a-f]{64}"\},$'
  let real = (read "mix.lock" | lines | where {|l| $l | str starts-with '  "bandit":' })
  let control = (read "test/fixtures/deps_audit/positive_control/mix.lock" | lines | where {|l| $l | str starts-with '  "bandit":' })
  assert equal ($real | length) 1 "mix.lock must have one bandit entry"
  assert equal ($control | length) 1 "the positive-control lock must have one bandit entry"
  assert ($real.0 =~ $shape) "the real mix.lock bandit entry must have the 8-element hex shape (update this test if mix changes the lock format)"
  assert ($control.0 =~ $shape) "the positive-control bandit entry must have the real lock's 8-element shape"
  assert ($control.0 | str contains ':bandit, "1.5.0",') "the positive control must lock bandit 1.5.0"
}

def t3-parity [] {
  let hex = (mix-exs-entries)
  let ignore = (ignore-file-entries)
  assert equal ($hex | get id | sort) ($ignore | get id | sort) "mix.exs ignore_advisories and .mix-audit-ignore must list the same IDs"

  assert (($root | path join ".mix-audit-ignore") | path exists) ".mix-audit-ignore must exist at the repo root"
  for line in (read ".mix-audit-ignore" | lines) {
    assert equal $line ($line | str trim) $".mix-audit-ignore lines must have no leading or trailing whitespace: '($line)'"
  }

  for e in $ignore {
    let hex_entry = ($hex | where id == $e.id)
    assert equal ($hex_entry | length) 1 $"($e.id) must appear once in mix.exs"
    assert equal (issue-number $e) (issue-number $hex_entry.0) $"($e.id) must name the same issue in both files"
  }
  for e in $hex { issue-number $e | ignore }

  for a in $aliases {
    assert (not ($a.cve in ($hex | get id))) $"mix.exs must use ($a.ghsa), not its alias ($a.cve)"
    assert (not ($a.cve in ($ignore | get id))) $".mix-audit-ignore must use ($a.ghsa), not its alias ($a.cve)"
  }
}

def t4-doc [] {
  review-gap-fixtures
  let sections = (doc-sections)
  let ignore = (ignore-file-entries)
  for id in ((mix-exs-entries | get id) | append ($ignore | get id) | uniq) {
    let matches = ($sections | where id == $id)
    assert equal ($matches | length) 1 $"($doc_path) must have one `## ($id)` section"
    let s = $matches.0
    assert equal ($s.subsections | get name) $subsections $"`## ($id)` must have the 14 ### subsections in order"

    let sub = {|name| $s.subsections | where name == $name | get 0.body }

    let entry = ($ignore | where id == $id)
    if ($entry | is-not-empty) {
      let n = (issue-number $entry.0)
      assert ((do $sub "Tracking") =~ $'issues/($n)\b') $"`## ($id)` ### Tracking must name issue ($n)"
    }

    assert ((do $sub "Owner") | str trim | is-not-empty) $"`## ($id)` ### Owner must not be empty"

    let trigger = (do $sub "Review trigger" | lines)
    let reviewed = ($trigger | parse --regex '^Reviewed: (?<d>\d{4}-\d{2}-\d{2})$')
    let next = ($trigger | parse --regex '^Next review: (?<d>\d{4}-\d{2}-\d{2})$')
    assert equal ($reviewed | length) 1 $"`## ($id)` ### Review trigger must have exactly one `Reviewed: YYYY-MM-DD` line"
    assert equal ($next | length) 1 $"`## ($id)` ### Review trigger must have exactly one `Next review: YYYY-MM-DD` line"
    assert ((parse-day $reviewed.0.d) != null) $"`## ($id)` Reviewed date is not a valid date: ($reviewed.0.d)"
    assert ((parse-day $next.0.d) != null) $"`## ($id)` Next review date is not a valid date: ($next.0.d)"
    assert (review-gap-ok $reviewed.0.d $next.0.d) $"`## ($id)` Next review \(($next.0.d)\) must be 1 to ($max_review_gap_days) days after Reviewed \(($reviewed.0.d)\)"
  }
}

def t5-orphans [] {
  let hex = (mix-exs-entries | get id)
  let ignore = (ignore-file-entries | get id)
  for s in (doc-sections) {
    assert ($s.id in $hex) $"doc section `## ($s.id)` must be on mix.exs ignore_advisories"
    assert ($s.id in $ignore) $"doc section `## ($s.id)` must be on .mix-audit-ignore"
  }
}

def t6-otp-wiring [] {
  let mise = (open ($root | path join "mise.toml"))
  let tasks = ($mise | get -o tasks | default {})
  let ci = ($tasks | get -o ci | default {} | get -o depends | default [])

  let otp_task = ($tasks | get -o "audit:otp")
  assert ($otp_task != null) "mise.toml must define [tasks.\"audit:otp\"]"
  assert equal (run-list $otp_task) ["nu scripts/otp-audit.nu --image-file docs/examples/Dockerfile.flame"] "audit:otp must run exactly `nu scripts/otp-audit.nu --image-file docs/examples/Dockerfile.flame` (no --floor override)"
  let test_task = ($tasks | get -o "test:otp-audit")
  assert ($test_task != null) "mise.toml must define [tasks.\"test:otp-audit\"]"
  assert equal (run-list $test_task) ["nu test/test-otp-audit.nu"] "test:otp-audit must run exactly `nu test/test-otp-audit.nu`"
  for t in ["audit:otp" "test:otp-audit"] {
    assert ($t in $ci) $"tasks.ci.depends must include ($t)"
  }

  let script = ($root | path join "scripts" "otp-audit.nu")
  assert ($script | path exists) "scripts/otp-audit.nu must exist"
  let floor_lines = (open --raw $script | lines | where {|l| $l =~ '^\s*const\s+otp_floor\b' })
  assert equal ($floor_lines | length) 1 $"scripts/otp-audit.nu must have exactly one `const otp_floor` line, got: ($floor_lines)"
  assert equal $floor_lines.0 'const otp_floor = "28.5.0.8"' "scripts/otp-audit.nu must set exactly `const otp_floor = \"28.5.0.8\"`"

  let tools = ($mise | get -o tools | default {})
  assert equal ($tools | get -o erlang) "28.5.0.8" "mise.toml must pin erlang = \"28.5.0.8\""
  assert equal ($tools | get -o elixir) "1.19.6-otp-28" "mise.toml must pin elixir = \"1.19.6-otp-28\""

  let df = ($root | path join "docs" "examples" "Dockerfile.flame")
  assert ($df | path exists) "docs/examples/Dockerfile.flame must exist"
  let froms = (open --raw $df | lines | where {|l| $l =~ '(?i)^\s*FROM\s+' } | each {|l| $l | str trim })
  assert (($froms | length) >= 2) $"docs/examples/Dockerfile.flame must have a builder and a runtime FROM, got: ($froms)"
  let builder = "hexpm/elixir:1.19.6-erlang-28.5.0.8-alpine-3.24.3"
  assert equal $froms.0 $"FROM ($builder) AS builder" $"the first FROM must be `FROM ($builder) AS builder`"
  let alpine = ($builder | parse --regex '-alpine-(?<v>[0-9.]+)$' | get 0.v)
  assert equal ($froms | last) $"FROM alpine:($alpine)" $"the runtime FROM must be `FROM alpine:($alpine)`, the builder tag's alpine"
}

def t7-dependabot [] {
  let file = ($root | path join ".github" "dependabot.yml")
  assert ($file | path exists) ".github/dependabot.yml must exist"
  let cfg = (open --raw $file | from yaml)
  assert ($cfg != null) ".github/dependabot.yml must parse to a mapping"
  assert equal ($cfg | get -o version) 2 ".github/dependabot.yml must have version: 2"
  let updates = ($cfg | get -o updates | default [])

  let mix = ($updates | where {|u| ($u | get -o "package-ecosystem") == "mix" })
  assert equal ($mix | length) 1 "dependabot.yml must have exactly one mix entry"
  assert equal (update-dirs $mix.0) ["/"] "the mix entry must cover exactly /"
  assert equal ($mix.0 | get -o schedule | default {} | get -o interval) "weekly" "the mix entry must run weekly"

  let gha = ($updates | where {|u| ($u | get -o "package-ecosystem") == "github-actions" })
  assert equal ($gha | length) 1 "dependabot.yml must have exactly one github-actions entry"
  assert equal (update-dirs $gha.0) ["/"] "the github-actions entry must be at /"
  assert equal ($gha.0 | get -o schedule | default {} | get -o interval) "weekly" "the github-actions entry must run weekly"

  for u in $updates {
    for d in (update-dirs $u) {
      assert (not ($d | str contains "*")) $"dependabot directory must not be a glob \(it would bump the positive-control fixture lock\): ($d)"
    }
  }
}

def main [] {
  let results = [
    {name: "T2 wiring", run: {|| t2-wiring }}
    {name: "T3 allow-list parity", run: {|| t3-parity }}
    {name: "T4 doc parity", run: {|| t4-doc }}
    {name: "T5 no orphans", run: {|| t5-orphans }}
    {name: "T5 fixture: doc-sections", run: {|| doc-sections-fixture }}
    {name: "T6 otp wiring", run: {|| t6-otp-wiring }}
    {name: "T7 dependabot", run: {|| t7-dependabot }}
  ] | each {|t|
    try {
      do $t.run
      print $"  [ok] ($t.name)"
      {name: $t.name, ok: true}
    } catch {|e|
      print $"  [FAIL] ($t.name): ($e.msg)"
      {name: $t.name, ok: false}
    }
  }
  if ($results | any {|r| not $r.ok }) {
    print "FAIL test:audit-wiring"
    exit 1
  }
  print "PASS test:audit-wiring"
}
