#!/bin/bash

if [ ! "$CI" = "true" ] || [ ! -f /.dockerenv ]; then
    echo `basename $0` "can run only in Circle CI"
    exit 1
fi

set -e

# cleanup if needed

git clean -dfx
rm -rf base

# build print_binable_functors, then run Python script to compare binable functors in a pull request
source ~/.profile && \
    (dune build --profile=dev src/external/ppx_version/src/print_binable_functors.exe) && \
    ./scripts/compare_pr_diff_binables.py ${CIRCLE_PULL_REQUEST}
