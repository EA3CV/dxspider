#!/bin/sh
set -eu
: "${DXS_HOST:=127.0.0.1}"
: "${DXS_PORT:=27754}"
: "${HTTP_PORT:=7380}"
export DXS_HOST DXS_PORT HTTP_PORT
exec perl app.pl daemon -l "http://0.0.0.0:${HTTP_PORT}"
