#!/bin/bash

: "${IIB_REGISTRY_URL:=localhost}"
: "${IIB_REGISTRY_PORT:=50051}"
: "${IIB_REGISTRY_NAME:=iib_registry_server}"

: "${IIB_EXPLORER_OUTPUT:=text}"

# This script uses gRPCurl
# https://github.com/fullstorydev/grpcurl
# More details the registry usage can be found at
# https://github.com/operator-framework/operator-registry

cli_options() {
  echo "-o,;--output; Output format text (default) or json"
  echo "-h,;--help; Print this help"
}

print_usage() {
  echo "Usage:"
  echo "    iib-explorer get packages"
  echo "    iib-explorer get package <package>"
  echo "    iib-explorer get bundles"
  echo "    iib-explorer get bundle <csv:package:channel>"
  echo ""
  echo "Options:"
  cli_options | awk '{ print "    " $1 }' | column -t -s ';' -o ' '
}

print_help() {
  echo "Description:"
  echo "    Command line tool for exploring index image bundles (iib)."
  echo ""
  print_usage
}

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

api() {
  local resource="${1}"
  if [[ -n "${resource}" ]]; then
    describe_api "${resource}"
  else
    list_api
  fi
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
  if [[ -z "${package}" ]]; then
    error "Specify package name!"
  fi
  local api="api.Registry/GetPackage"
  local data="{\"name\":\"$package\"}"
  local resources
  resources=$(get_resources "${api}" "${data}")
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
  echo ""
  print_usage
  exit "$exit_code"
}

execute_cmd() {
  local cmd
  local cmd_args
  local cli_function

  cmd=$(echo "${1}_" | tr ' ' '_')
  for f in $(compgen -A function); do
    if [[ "${cmd}" =~ ^${f}_ ]]; then
      if [[ -n "${cli_function}" ]]; then
        error "Ambigious command '${cmd}' (matches '${cli_function}' and '${f}')"
      fi
      cli_function="${f}"
    fi
  done
  if [[ -n "${cli_function}" ]]; then
    cmd_args="${cmd#"${cli_function}"}"
    cmd_args=$(echo "${cmd_args}" | tr '_' ' ')
    eval "${cli_function} ${cmd_args}"
  else
    error "Unsupported command '${cmd}'"
  fi
}

main() {
  local iib="${IIB}"
  local api
  local data
  local package
  local command=""

  local operation="${1}"
  local resource_type="${2}"
  local resource_name="${3}"

  while [[ $# -gt 0 ]]; do
    local key="${1}"
    case $key in
    -o | --output)
      IIB_EXPLORER_OUTPUT="${2}"
      shift # past argument
      shift # past value
      ;;
    -h | --help) # print usage
      print_help
      exit
      ;;
    *) # unknown option is considered as part of command
      if [[ -n "${command}" ]]; then
        command+=" ${1}"
      else
        command+="${1}"
      fi
      shift # past argument
      ;;
    esac
  done

  echo "execute '${command}'"

  if [[ -z "${iib}" ]]; then
    error "Specify an index image!"
  fi

  if [[ "${IIB_EXPLORER_OUTPUT}" != "text" && "${IIB_EXPLORER_OUTPUT}" != "json" ]]; then
    error "Unsupported output '${IIB_EXPLORER_OUTPUT}'!"
  fi
  
  run_registry_server "${iib}" > /dev/null

  local result=""
  result=$(execute_cmd "${command}")

  stop_registry_server > /dev/null

  if [[ "${IIB_EXPLORER_OUTPUT}" == text ]]; then
    local header=$(echo "${result}" | head -n1)
    local data=$(echo "${result}" | tail -n+2 | sort -t ',')
    (echo "${header}"; echo "${data}") | column -t -s ','
  else
    echo "${result}"
  fi
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
