#!/bin/zsh
# Headless tests for the vim engine: extracts it from the real source and runs it against NSTextView.
T=${0:a:h}
SRC=${T:h:h}/FSNotes/View/EditTextView+MoveLines.swift
OUT=${TMPDIR:-/tmp}/fsnotes-vimtests; mkdir -p $OUT
A=$(grep -n "^// MARK: - Vim mode (basic)" $SRC | cut -d: -f1)
B=$(grep -n "^// MARK: - EditTextView glue" $SRC | cut -d: -f1)
{ cat $T/header.swift; sed -n "${A},$((B-1))p" $SRC; cat $T/harness.swift $T/tests_*.swift; echo 'print(fails == 0 ? "ALL PASSED" : "\(fails) FAILED")'; } > $OUT/main.swift
cd $OUT && swiftc -O main.swift -o vimtest 2>&1 | grep -E "error" | head; ./vimtest
