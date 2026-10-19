#!/bin/bash
set -e
cd "$(dirname "$0")"
mkdir -p build
cp Tests/CoreTests.swift build/main.swift
swiftc Sources/Core.swift build/main.swift -o build/core_tests
./build/core_tests
