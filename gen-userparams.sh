#!/bin/bash -e

find -name userparams.conf -exec cat {} \; | tee userparams_mconf.conf
