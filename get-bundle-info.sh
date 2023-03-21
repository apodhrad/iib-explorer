#!/bin/sh

: "${IIB_REGISTRY_URL:=localhost}"
: "${IIB_REGISTRY_PORT:=50051}"
: "${IIB_REGISTRY_NAME:=iib_registry_server}"

# This script uses gRPCurl
# https://github.com/fullstorydev/grpcurl
# More details the registry usage can be found at
# https://github.com/operator-framework/operator-registry

inspect() {
  local line="$1"
  if [[ -n "$line" ]]; then
    podman pull -q "$line" > /dev/null && podman inspect "$line" | jq -r '.[0] | (.Labels.version + "-" +  .Labels.release) as $Version | { Id, Digest, $Version }'
  else
    while read line; do
      inspect "$line"
    done
  fi
}

run_registry_server() {
  local iib="$1"
  stop_registry_server "$iib"
  podman run -d --name "$IIB_REGISTRY_NAME" -p "$IIB_REGISTRY_PORT":50051 "$iib"
}

stop_registry_server() {
  podman rm "$IIB_REGISTRY_NAME" -f -i
}

get_package() {
  local package="$1"
  grpcurl -plaintext -d "{\"name\":\"$package\"}" "$IIB_REGISTRY_URL:$IIB_REGISTRY_PORT" api.Registry/GetPackage
}

get_packages() {
  grpcurl -plaintext "$IIB_REGISTRY_URL:$IIB_REGISTRY_PORT" api.Registry/ListPackages
}

get_bundles() {
  local package="$1"
  local channel="$2"
  grpcurl -plaintext "$IIB_REGISTRY_URL:$IIB_REGISTRY_PORT" api.Registry/ListBundles | tee /tmp/all-bundles.json | jq --arg package "$package" --arg channel "$channel" -r 'select(.packageName == $package and .channelName == $channel) | { csvName, packageName, channelName, bundlePath, version, replaces }'
}

get_specific_bundle() {
  local package="$1"
  local channel="$2"
  local version="$3"
  local output_format="$4"
  local bundle=$(grpcurl -plaintext "$IIB_REGISTRY_URL:$IIB_REGISTRY_PORT" api.Registry/ListBundles | tee /tmp/all-bundles.json | jq --arg package "$package" --arg channel "$channel" --arg version "$version" -r 'select(.packageName == $package and .channelName == $channel and .version == $version)') 
  local csv_json=$(echo "$bundle" | jq -r '.csvJson')
  local bundle=$(echo "$bundle" | jq --argjson csv_json "$csv_json" -r '.csvJson=$csv_json')
  if [[ "$output_format" == "plain" ]]; then
    echo "$bundle" | jq -r .
  else
    local bundle=$(echo "$bundle" | jq -r '.csvJson.metadata.annotations.containerImage as $containerImage | { csvName, packageName, channelName,  bundlePath, $containerImage}')
    local bundlePathInspect=$(echo "$bundle" | jq -r '.bundlePath' | inspect)
    local containerImageInspect=$(echo "$bundle" | jq -r '.containerImage' | inspect)
    echo "$bundle" "{\"bundlePathInspect\": $bundlePathInspect}" "{\"containerImageInspect\": $containerImageInspect}" | jq -s add | jq -r '{ csvName, packageName, channelName,  bundlePath, bundlePathInspect, containerImage, containerImageInspect}'
  fi
}

get_bundle() {
  local package="$1"
  local channel="$2"
  grpcurl -plaintext -d "{\"pkgName\":\"$package\",\"channelName\":\"$channel\"}" "$IIB_REGISTRY_URL:$IIB_REGISTRY_PORT" api.Registry/GetBundleForChannel
}

print_bundle() {
  local bundle="$1"
  local csv_json=$(echo "$bundle" | jq -r '.csvJson')
  local alm_examples=$(echo "$csv_json" | jq -r '.metadata.annotations."alm-examples"')
  csv_json=$(echo "$csv_json" | jq --argjson alm_examples "$alm_examples" -r '.metadata.annotations."alm-examples"=$alm_examples')
  bundle=$(echo "$bundle" | jq --argjson csv_json "$csv_json" -r '.csvJson=$csv_json')
  echo "$bundle" | jq -r 'del(.object)'
}

error() {
  local msg="$1"
  local exit_code="${2:-1}"
  echo "[ERROR] $msg"
  exit "$exit_code"
}

main() {
  INDEX_IMAGE="$1"
  PACKAGE_NAME="$2"
  CHANNEL_NAME="$3"
  ALL_BUNDLES="$4"
  OUTPUT_FORMAT="$5"

  if [[ -z "$INDEX_IMAGE" ]]; then
    error "Specify an index image!"
  fi

  run_registry_server "$INDEX_IMAGE" > /dev/null

  if [[ -n "$PACKAGE_NAME" ]]; then
    if [[ -n "$CHANNEL_NAME" ]]; then
      if [[ "$ALL_BUNDLES" == "all" ]]; then
        get_bundles "$PACKAGE_NAME" "$CHANNEL_NAME"
      elif [[ -n "$ALL_BUNDLES" ]]; then
        get_specific_bundle "$PACKAGE_NAME" "$CHANNEL_NAME" "$ALL_BUNDLES" "$OUTPUT_FORMAT"
      else
        BUNDLE=$(get_bundle "$PACKAGE_NAME" "$CHANNEL_NAME")
        print_bundle "$BUNDLE"
      fi
    else
      get_package "$PACKAGE_NAME"
    fi
  else
    get_packages
  fi

  stop_registry_server > /dev/null
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
