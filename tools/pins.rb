#!/usr/bin/env ruby
# frozen_string_literal: true

# pins.rb — read versions.yaml (the repo's pin SSOT) and emit KEY=VALUE
# lines for $GITHUB_ENV.
#
#   ruby tools/pins.rb <triplet> <tool-platform> [--env]
#   ruby tools/pins.rb --release
#   ruby tools/pins.rb --installer-env <triplet>
#
# Press mode:
#   <triplet>        the feedstock triplet (aarch64-macos,
#                    x86_64-linux-gnu, x86_64-windows-ucrt) — selects the
#                    payload slice assets
#   <tool-platform>  the tebako toolchain/runtime asset platform
#                    (macos-arm64, linux-gnu-x86_64, windows-ucrt64) —
#                    selects the tebako-pkg/tebako-bootstrap/tfs assets
#
# Release mode (--release): emits the flat keys the release notes need
# (versions + release tags), no per-platform selection.
#
# Installer mode (--installer-env): the installer legs' env (spec 16 §7) —
# the product binds + the four PATH tools' asset names and sha256 pins for
# the leg's triplet (aarch64-macos, x86_64-macos; x86_64-windows-ucrt maps
# for the parked MSI leg). Never touches the payload slice pins: the seed
# resolves the metanorma payload from the feedstock REGISTRY at install
# time, and x86_64-macos has no slice pins in versions.yaml (the press
# matrix never builds one) — resolving slices here would fail the leg on
# an input it does not consume.
#
# With --env the output is KEY=VALUE lines (append to $GITHUB_ENV);
# without it the pairs print as shell export lines. Unknown triplet /
# missing pin is a named error, never a guess (spec 00 §9).

require "yaml"

# Native windows ruby terminates text-mode lines with CRLF and every
# consumer (GITHUB_ENV, bash `read`) keeps the \r — a tainted value
# malforms downstream steps. binmode is a no-op on POSIX.
$stdout.binmode

def die(msg)
  warn "pins.rb: #{msg}"
  exit 64
end

root = File.expand_path("..", __dir__)
doc = YAML.load_file(File.join(root, "versions.yaml"))
die "versions.yaml: schema_version missing (pre-era document?)" unless doc["schema_version"] == 1

tebako = doc.fetch("tebako")
runtime = doc.fetch("runtime")
package = doc.fetch("package")
payloads = doc.fetch("payloads")

by_name = payloads.to_h { |p| [p["name"], p] }

if ARGV.include?("--release")
  notes = {
    "PKG_VERSION" => package.fetch("version"),
    "TEBAKO_VERSION" => tebako.fetch("version"),
    "RUNTIME_RUBY_NOTE" => runtime.fetch("ruby"),
    "RUNTIME_TEBAKO_NOTE" => runtime.fetch("tebako"),
    "MN_RELEASE_NOTE" => by_name.fetch("metanorma").fetch("release"),
    "JDK_RELEASE_NOTE" => by_name.fetch("openjdk").fetch("release"),
    "INK_RELEASE_NOTE" => by_name.fetch("inkscape").fetch("release"),
    "X2RFC_RELEASE_NOTE" => by_name.fetch("xml2rfc").fetch("release"),
  }
  notes.each { |k, v| puts "#{k}=#{v}" }
  exit 0
end

if ARGV[0] == "--installer-env"
  itriplet = ARGV[1] or die "usage: pins.rb --installer-env <triplet>"
  # Installer-leg triplet → tebako toolchain asset platform (the press
  # matrix carries the two as separate columns; the installer matrix is
  # the two macOS triplets, windows-ucrt64 mapping for the parked MSI
  # leg — its tebako/tebako-shim pins land in versions.yaml at unpark).
  itool = {
    "aarch64-macos" => "macos-arm64",
    "x86_64-macos" => "macos-x86_64",
    "x86_64-windows-ucrt" => "windows-ucrt64",
  }[itriplet] or die "pins.rb: no installer leg for triplet #{itriplet}"

  inst = doc.fetch("installers")
  iversion = tebako.fetch("version")
  iexe = itool.start_with?("windows") ? ".exe" : ""
  iasset = ->(name) { "#{name}-#{iversion}-#{itool}#{iexe}" }
  isha = lambda do |name|
    tebako.dig("sha256", name, itool) or
      die "versions.yaml: no tebako.sha256.#{name}.#{itool} pin"
  end

  ipairs = {
    "TRIPLET" => itriplet,
    "HOST_ID" => itool,
    "PKG_VERSION" => package.fetch("version"),
    "TEBAKO_VERSION" => iversion,
    "TEBAKO_RELEASE" => tebako.fetch("release"),
    # The four PATH tools the installer stages (spec 16 §7); the pins
    # double as the sign-then-hash anchors — the release's bytes are
    # already signed, so the pin is exactly the fragment the ci script
    # re-verifies its staging against.
    "TEBAKO_ASSET" => iasset.call("tebako"),
    "TEBAKO_SHA256" => isha.call("tebako"),
    "SHIM_ASSET" => iasset.call("tebako-shim"),
    "SHIM_SHA256" => isha.call("tebako-shim"),
    "TFS_ASSET" => iasset.call("tfs"),
    "TFS_SHA256" => isha.call("tfs"),
    "PKG_ASSET" => iasset.call("tebako-pkg"),
    "PKG_SHA256" => isha.call("tebako-pkg"),
    "PRODUCT_NAME" => inst.fetch("product_name"),
    "MANUFACTURER" => inst.fetch("manufacturer"),
    "ORG_ID" => inst.fetch("org_id"),
    "INSTALL_ROOT" => inst.fetch("install_root"),
    "MSI_UPGRADE_CODE" => inst.fetch("msi_upgrade_code"),
    "TEBAKO_INSTALLER_REF" => inst.fetch("installer_ref"),
    # The web-bootstrapper seed (spec 16 §7): the product's same-named
    # registry payload, installed from the feedstock registry at install
    # time; the warm dispatches it once so the runtime lands in the
    # root-owned machine home — a user dispatch is read-only after the
    # warm (the seed runs no timeout: bare `metanorma` is bounded
    # print-and-exit).
    "BOOTSTRAP_REGISTRY" => inst.fetch("registry"),
    "BOOTSTRAP_PAYLOADS" => package.fetch("name"),
    "BOOTSTRAP_WARM" => package.fetch("name"),
  }
  ipairs.each { |k, v| puts "#{k}=#{v}" }
  exit 0
end

triplet = ARGV[0] or die "usage: pins.rb <triplet> <tool-platform> [--env] | pins.rb --release | pins.rb --installer-env <triplet>"
tool = ARGV[1] or die "usage: pins.rb <triplet> <tool-platform> [--env] | pins.rb --release | pins.rb --installer-env <triplet>"

tool_sha = lambda do |name|
  tebako.dig("sha256", name, tool) or
    die "versions.yaml: no tebako.sha256.#{name}.#{tool} pin"
end

slice = lambda do |name|
  p = by_name[name] or die "versions.yaml: no payloads[] entry named #{name}"
  a = p.dig("assets", triplet) or
    die "versions.yaml: payload #{name} has no asset for triplet #{triplet}"
  [p, a]
end

mn_p, mn = slice.call("metanorma")
jdk_p, jdk = slice.call("openjdk")
ink_p, ink = slice.call("inkscape")
# spec 32's spawned payload: the xml2rfc slice + its nested python runtime
# pair. A triplet with no asset (windows today — no windows xml2rfc payload
# or python runtime exists) dies here on slice.call's named error: the leg
# fails CLOSED, never a silent skip of the spawn edge.
x2_p, x2 = slice.call("xml2rfc")

windows = tool.start_with?("windows")
# The runtime root's DECLARED spelling (spec 17 §1): /__tfs__ on POSIX,
# /t on windows (the driver re-qualifies onto the VFS drive, A:/t).
runtime_root = windows ? "/t" : "/__tfs__"
exe = windows ? ".exe" : ""
version = tebako.fetch("version")

asset = ->(name) { "#{name}-#{version}-#{tool}#{exe}" }

pairs = {
  "TEBAKO_VERSION" => version,
  "TEBAKO_RELEASE" => tebako.fetch("release"),
  "TEBAKO_PKG_ASSET" => asset.call("tebako-pkg"),
  "TEBAKO_PKG_SHA256" => tool_sha.call("tebako-pkg"),
  "TEBAKO_BOOTSTRAP_ASSET" => asset.call("tebako-bootstrap"),
  "TEBAKO_BOOTSTRAP_SHA256" => tool_sha.call("tebako-bootstrap"),
  "TFS_ASSET" => asset.call("tfs"),
  "TFS_SHA256" => tool_sha.call("tfs"),
  "RUNTIME_REF" => "ruby@#{runtime.fetch('ruby')};tebako=#{runtime.fetch('tebako')};image",
  "RUNTIME_RUBY" => runtime.fetch("ruby"),
  "RUNTIME_TEBAKO" => runtime.fetch("tebako"),
  "PKG_VERSION" => package.fetch("version"),
  "RUNTIME_ROOT" => runtime_root,
  "LAUNCHER_ABI" => "1",
  "EXE_SUFFIX" => exe,
  "MN_RELEASE" => mn_p.fetch("release"),
  "MN_VERSION" => mn_p.fetch("version"),
  "MN_FILE" => mn.fetch("file"),
  "MN_SHA256" => mn.fetch("sha256"),
  "JDK_RELEASE" => jdk_p.fetch("release"),
  # The runtime-kind identity (spec 30): the spawned lock row's version
  # pair, and the exe facet pins (the pair rides slots 1-2, claimed by
  # lock.spawned[] — never mounted).
  "JDK_LANG" => jdk_p.fetch("lang_version"),
  "JDK_TEBAKO" => jdk_p.fetch("tebako_version"),
  "JDK_FILE" => jdk.fetch("file"),
  "JDK_SHA256" => jdk.fetch("sha256"),
  "JDK_EXE_FILE" => jdk.fetch("exe_file"),
  "JDK_EXE_SHA256" => jdk.fetch("exe_sha256"),
  "INK_RELEASE" => ink_p.fetch("release"),
  "INK_VERSION" => ink_p.fetch("version"),
  "INK_FILE" => ink.fetch("file"),
  "INK_SHA256" => ink.fetch("sha256"),
  # The spawned-payload identity (spec 32 §6): the provider payload's
  # version + image pin, and the NESTED python runtime row's version pair
  # + pair pins (the trio rides slots 4-6, claimed by the lock's spawned[]
  # payload row — never mounted by the parent).
  "X2RFC_RELEASE" => x2_p.fetch("release"),
  "X2RFC_VERSION" => x2_p.fetch("version"),
  "X2RFC_FILE" => x2.fetch("file"),
  "X2RFC_SHA256" => x2.fetch("sha256"),
  "PY_RELEASE" => x2_p.fetch("python_release"),
  "PY_LANG" => x2_p.fetch("lang_version"),
  "PY_TEBAKO" => x2_p.fetch("tebako_version"),
  "PY_EXE_FILE" => x2.fetch("py_exe_file"),
  "PY_EXE_SHA256" => x2.fetch("py_exe_sha256"),
  "PY_IMAGE_FILE" => x2.fetch("py_image_file"),
  "PY_IMAGE_SHA256" => x2.fetch("py_image_sha256"),
}

if ARGV.include?("--env")
  pairs.each { |k, v| puts "#{k}=#{v}" }
else
  pairs.each { |k, v| puts "export #{k}=#{v}" }
end
