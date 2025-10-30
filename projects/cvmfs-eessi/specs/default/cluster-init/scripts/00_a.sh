#!/bin/bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

source "$SCRIPT_DIR/../files/myenv"
printenv | grep FOO
