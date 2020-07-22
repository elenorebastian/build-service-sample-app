#!/bin/sh

set -e -u -

cd source-code/
./gradlew build
./gradlew test



