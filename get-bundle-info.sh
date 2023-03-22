#!/bin/sh

: "${IIB_REGISTRY_URL:=localhost}"
: "${IIB_REGISTRY_PORT:=50051}"
: "${IIB_REGISTRY_NAME:=iib_registry_server}"

: "${IIB_EXPLORER_OUTPUT:=text}"

# This script uses gRPCurl
# https://github.com/fullstorydev/grpcurl
# More details the registry usage can be found at
# https://github.com/operator-framework/operator-registry

run_registry_server() {
  local iib="$1"
  stop_registry_server "$iib"
  podman run -d --name "$IIB_REGISTRY_NAME" -p "$IIB_REGISTRY_PORT":50051 "$iib"
}

stop_registry_server() {
  podman rm "$IIB_REGISTRY_NAME" -f -i
}

get_api() {
  grpcurl -plaintext "$IIB_REGISTRY_URL:$IIB_REGISTRY_PORT" "$@"
}

list_api() {
  local services=$(get_api "list" | paste -sd " ")
  local services_json=""
  for service in ${services}; do
    local methods=$(get_api "list" "${service}")
    local methods_json=$(echo -n "${methods}" | jq -cRs 'split("\n")')
    services_json+="{\"name\":\"${service}\",\"methods\":${methods_json}}"
  done
  services_json=$(echo "${services_json}" | jq -s)
  if [[ "${IIB_EXPLORER_OUTPUT}" == "text" ]]; then
    # headers
    echo "SERVICE,METHOD"
    # data
    echo "${services_json}" | jq -r '.[] | .name as $service | .methods[] as $method | $service + "," + $method'
  else
    echo "${services_json}"
  fi
}

describe_api() {
  get_api "describe" "${1}"
}

get_resources() {
  local api="${1}"
  local data="${2}"
  if [[ -z "${data}" ]]; then
    grpcurl -plaintext "$IIB_REGISTRY_URL:$IIB_REGISTRY_PORT" "${api}"
  else
    grpcurl -plaintext -d "${data}" "$IIB_REGISTRY_URL:$IIB_REGISTRY_PORT" "${api}"
  fi
}

get_packages() {
  local api="api.Registry/ListPackages"
  local resources=$(get_resources "${api}")
  if [[ "${IIB_EXPLORER_OUTPUT}" == "text" ]]; then
    # headers
    echo "PACKAGE"
    # data
    echo "${resources}" | jq -r '.name'
  else
    echo "${resources}" | jq -r "."
  fi
}

get_package() {
  local package="${1}"
  local api="api.Registry/GetPackage"
  local data="{\"name\":\"$package\"}"
  local resources=$(get_resources "${api}" "${data}")
  if [[ "${IIB_EXPLORER_OUTPUT}" == "text" ]]; then
    # headers
    echo "PACKAGE,CHANNEL,CSV,DEFAULT"
    # data
    echo "${resources}" | jq -r '.name as $package | .defaultChannelName as $default | .channels[] | {$package,name,csvName, $default} | if .name == $default then .default="true" else .default="" end | .package + "," + .name + "," + .csvName + "," + .default'
  else
    echo "${resources}" | jq -r "."
  fi
}

get_bundles() {
  local api="api.Registry/ListBundles"
  local resources=$(get_resources "${api}" | jq -r 'del(.object,.csvJson)')
  if [[ "${IIB_EXPLORER_OUTPUT}" == "text" ]]; then
    # headers
    echo "CSV,PACKAGE,CHANNEL"
    # data
    echo "${resources}" | jq -r '.csvName + "," + .packageName + "," + .channelName'
  elif [[ "${IIB_EXPLORER_OUTPUT}" == "json" ]]; then
    echo "${resources}" | jq -r '.'
  else
    echo "${resources}"
  fi
}

get_bundle() {
  local bundle="${1}"
  if [[ ! "${resource_name}" =~ ^.+:.+:.+$ ]]; then
    error "Specify the resiurce in the format 'csv:package:channel'!"
  fi
  local api="api.Registry/GetBundle"
  local data=$(echo "${resource_name}" | awk -F ':' '{ print "{\"pkgName\":\"" $2 "\",\"channelName\":\"" $3 "\",\"csvName\":\"" $1 "\"}" }')
  local resources=$(get_resources "${api}" "${data}")
  if [[ "${IIB_EXPLORER_OUTPUT}" == "text" ]]; then
    # headers
    echo "CSV,PACKAGE,CHANNEL"
    # data
    echo "${resources}" | jq -r '.csvName + "," + .packageName + "," + .channelName'
  elif [[ "${IIB_EXPLORER_OUTPUT}" == "json" ]]; then
    echo "${resources}" | jq -r '.'
  else
    echo "${resources}"
  fi
}

warn() {
  local msg="$1"
  echo "[WARN] $msg"
}

error() {
  local msg="$1"
  local exit_code="${2:-1}"
  echo "[ERROR] $msg"
  exit "$exit_code"
}

main() {
  local iib="${IIB}"
  local api
  local data
  local package

  local operation="${1}"
  local resource_type="${2}"
  local resource_name="${3}"

  while [[ $# -gt 0 ]]; do
    local key="${1}"
    case $key in
    -i | --iib)
      iib="${2}"
      shift # past argument
      shift # past value
      ;;
    -o | --output)
      IIB_EXPLORER_OUTPUT="${2}"
      shift # past argument
      shift # past value
      ;;
    --api)
      api="${2}"
      shift # past argument
      shift # past value
      ;;
    --data)
      data="${2}"
      shift # past argument
      shift # past value
      ;;
    --package)
      package="${2}"
      shift # past argument
      shift # past value
      ;;
    -h | --help) # print usage
      print_usage
      exit
      ;;
    *) # unknown option
      unknown="$1"
      shift
      ;;
    esac
  done

  if [[ -z "${iib}" ]]; then
    error "Specify an index image!"
  fi

  if [[ "${IIB_EXPLORER_OUTPUT}" != "text" && "${IIB_EXPLORER_OUTPUT}" != "json" ]]; then
    error "Unsupported output '${output}'!"
  fi
  
  run_registry_server "${iib}" > /dev/null

  local result=""
  case $operation in
    get)
      case $resource_type in
        packages)
          result=$(get_packages)
          ;;
        package)
          if [[ -z "${resource_name}" ]]; then
            error "Specify a resource name!"
          fi
          result=$(get_package "${resource_name}")
          ;;
        bundles)
          result=$(get_bundles)
          ;;
        bundle)
          if [[ -z "${resource_name}" ]]; then
            error "Specify a resource name!"
          fi
          result=$(get_bundle "${resource_name}")
          ;;
        *)
          error "Unsupported resource type '${resource_type}'!"
          ;;
      esac
      ;;
    api)
      if [[ -z "${resource_type}" ]]; then
        result=$(list_api)
      else
        warn "The output is not formatted as this is a direct output from grpcurl."
        IIB_EXPLORER_OUTPUT="grpcurl"
        result=$(describe_api "${resource_type}")
      fi
      ;;
    *)
      error "Unsupported operation '${operation}'!"
      ;;
  esac
  
  #get_resources "${api}" "${data}"
  #if [[ -n "${package}" ]]; then
  #  result=$(get_package2 "${package}" "${output}")
  #else
  #  result=$(list_packages "${output}")
  #fi

  if [[ "${IIB_EXPLORER_OUTPUT}" == text ]]; then
    echo "${result}" | column -t -s ','
  else
    echo "${result}"
  fi

  stop_registry_server > /dev/null
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
