#!/usr/bin/env bash

selected=`cat ~/.git_conflict_branches | fzf --prompt="λ "`

if [[ -z $selected ]]; then
    exit 0
fi

git checkout $selected
