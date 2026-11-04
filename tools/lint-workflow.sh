#!/bin/sh
# iSH 下 Go 二进制需单线程，否则 runtime panic
GOMAXPROCS=1 exec actionlint "$@"
