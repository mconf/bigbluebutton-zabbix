#!/bin/bash -e

cd "$( dirname "${BASH_SOURCE[0]}" )"

# https://www.cyberciti.biz/faq/check-linux-server-for-spectre-meltdown-vulnerability/
if [ ! -f spectre-meltdown-checker.sh ]; then
    wget https://raw.githubusercontent.com/speed47/spectre-meltdown-checker/master/spectre-meltdown-checker.sh
fi
