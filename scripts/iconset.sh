#!/usr/bin/env bash

create_kurotty_iconset() {
  local source_png="$1"
  local iconset_dir="$2"

  rm -rf "$iconset_dir"
  mkdir -p "$iconset_dir"

  local specs=(
    "16 16 icon_16x16.png"
    "32 32 icon_16x16@2x.png"
    "32 32 icon_32x32.png"
    "64 64 icon_32x32@2x.png"
    "128 128 icon_128x128.png"
    "256 256 icon_128x128@2x.png"
    "256 256 icon_256x256.png"
    "512 512 icon_256x256@2x.png"
    "512 512 icon_512x512.png"
  )

  local spec height_px width_px output_name
  for spec in "${specs[@]}"; do
    read -r height_px width_px output_name <<<"$spec"
    sips -z "$height_px" "$width_px" "$source_png" --out "$iconset_dir/$output_name" >/dev/null
  done

  cp "$source_png" "$iconset_dir/icon_512x512@2x.png"
}
