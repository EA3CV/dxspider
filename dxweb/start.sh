#!/bin/sh
#
# DXSpider Web launcher
#
# Starts the DXSpider Web service with its configured local DXSpider link.
#
# Copyright (c) 2026 Dirk Koopman G1TLH
#
set -eu
: "${DXS_HOST:=127.0.0.1}"
: "${DXS_PORT:=27754}"
: "${HTTP_PORT:=7380}"
export DXS_HOST DXS_PORT HTTP_PORT
exec perl app.pl daemon -l "http://0.0.0.0:${HTTP_PORT}"
