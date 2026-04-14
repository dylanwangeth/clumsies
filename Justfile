set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

dev interval="1000":
    INTERVAL="{{interval}}" ./scripts/dev/run-dev.sh
