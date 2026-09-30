#!/usr/bin/env ruby
# frozen_string_literal: true

# sync-payload.rb — flow a new metanorma payload version from the
# feedstock's tpkg-registry.yaml into this repo's versions.yaml.
#
#   ruby tools/sync-payload.rb <version> <registry.yaml>
#
# Updates exactly: package.version, and the metanorma payload's
# release tag + per-triplet file/sha256. The other payload slices
# (openjdk, xml2rfc) and the tebako/runtime pins are deliberately NOT
# touched — those bumps stay manual. Edits are line-oriented so comments and
# formatting survive (a Psych round-trip would strip them).
# Unrecognized shape in either file is a named error (exit 64), never
# a guess (spec 00 §9).

require "yaml"

def die(msg)
  warn "sync-payload.rb: #{msg}"
  exit 64
end

TRIPLETS = %w[aarch64-macos x86_64-linux-gnu x86_64-windows-ucrt].freeze

version = ARGV[0] or die "usage: sync-payload.rb <version> <registry.yaml>"
registry_path = ARGV[1] or die "usage: sync-payload.rb <version> <registry.yaml>"
die "malformed version '#{version}'" unless version.match?(/\A\d+\.\d+\.\d+\z/)

root = File.expand_path("..", __dir__)
versions_path = File.join(root, "versions.yaml")

# --- read the registry (the upstream SSOT for slice digests) -------------

registry = YAML.load_file(registry_path)
entry = registry.fetch("payloads").find { |p| p["name"] == "metanorma" } or
  die "registry has no payloads[] entry named metanorma"
v = entry.fetch("versions").find { |x| x["version"] == version } or
  die "registry metanorma entry has no version #{version}"

ref = v.dig("release", "ref") or die "registry #{version}: no release.ref"
release = ref.split(":").last
die "registry #{version}: unparseable release.ref '#{ref}'" if release.nil? || release.empty?

platforms = v.fetch("platforms")
assets = TRIPLETS.to_h do |t|
  a = platforms[t] or die "registry #{version}: no platform #{t}"
  file = a["artifact"] or die "registry #{version}/#{t}: no artifact"
  sha = a["sha256"] or die "registry #{version}/#{t}: no sha256"
  die "registry #{version}/#{t}: malformed sha256 '#{sha}'" unless sha.match?(/\A[0-9a-f]{64}\z/i)
  [t, { "file" => file, "sha256" => sha.downcase }]
end

# --- rewrite versions.yaml line-wise --------------------------------------

lines = File.readlines(versions_path, chomp: true)

# package.version — scoped to the top-level `package:` block so a payload's
# own `version:` key can never match.
pkg_start = lines.index { |l| l =~ /\Apackage:\s*\z/ } or
  die "versions.yaml: no top-level package: block"
pkg_end = lines.each_index.find { |i| i > pkg_start && lines[i] =~ /\A\S/ } || lines.length
pv = (pkg_start...pkg_end).select { |i| lines[i] =~ /\A  version: / }
die "versions.yaml: package.version not found" unless pv.length == 1
lines[pv[0]] = lines[pv[0]].sub(/\A(  version: )\S+(.*)\z/, "\\1#{version}\\2")

# metanorma payload block: from `  - name: metanorma` to the next
# `  - name:` (payloads is a top-level list of two-space-dash entries).
mn_start = lines.index { |l| l =~ /\A  - name: metanorma\s*\z/ } or
  die "versions.yaml: no '  - name: metanorma' payload entry"
mn_end = lines.each_index.find { |i| i > mn_start && lines[i] =~ /\A  - name: / } || lines.length
block = (mn_start...mn_end).to_a

scoped = lambda do |pattern, replacement, what|
  hits = block.select { |i| lines[i] =~ pattern }
  die "versions.yaml: metanorma.#{what} not found (shape changed? edit by hand)" unless hits.length == 1
  lines[hits[0]] = lines[hits[0]].sub(pattern, replacement)
end

scoped.call(/\A(    release: )\S+(.*)\z/, "\\1#{release}\\2", "release")

TRIPLETS.each do |t|
  t_start = block.find { |i| lines[i] =~ /\A      #{t}:\s*\z/ } or
    die "versions.yaml: metanorma.assets.#{t} not found"
  t_end = block.find { |i| i > t_start && lines[i] =~ /\A      \S/ } || mn_end
  seg = (t_start...t_end).to_a
  file_hits = seg.select { |i| lines[i] =~ /\A        file: / }
  sha_hits = seg.select { |i| lines[i] =~ /\A        sha256: / }
  die "versions.yaml: metanorma.assets.#{t}.file not found" unless file_hits.length == 1
  die "versions.yaml: metanorma.assets.#{t}.sha256 not found" unless sha_hits.length == 1
  lines[file_hits[0]] = lines[file_hits[0]].sub(/\A(        file: )\S+(.*)\z/, "\\1#{assets[t]['file']}\\2")
  lines[sha_hits[0]] = lines[sha_hits[0]].sub(/\A(        sha256: )\S+(.*)\z/, "\\1#{assets[t]['sha256']}\\2")
end

File.write(versions_path, lines.join("\n") + "\n")
warn "sync-payload.rb: metanorma payload -> #{version} (release #{release})"
