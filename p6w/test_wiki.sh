#!/bin/sh

QS=$1
set -u PARROT_DIR
REQUEST_METHOD=GET \
QUERY_STRING=$QS \
exec $PARROT_DIR/parrot $PARROT_DIR/languages/perl6/perl6.pbc wiki
