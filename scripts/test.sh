#!/bin/zsh
set -eu
cd "${0:A:h:h}"
app="./MacDuo.app/Contents/MacOS/DuoFoldDesktop"
for test in session repeat-lifecycle interaction-handoff standby recovery menu-actions hinge-sound attention lower-sharp; do
 "$app" "--test-$test"
done
