#!/bin/sh
# Xcode Cloud runs this after each xcodebuild action. After an archive, it
# writes the TestFlight "What to Test" notes from the latest merges to the
# branch, using each pull request's title. A failure here only skips the notes.

if [ "$CI_XCODEBUILD_ACTION" != "archive" ]; then
  exit 0
fi

notes_dir="$CI_PRIMARY_REPOSITORY_PATH/apps/mobile/MeetingScheduler/TestFlight"
mkdir -p "$notes_dir" || exit 0

git -C "$CI_PRIMARY_REPOSITORY_PATH" log -10 --first-parent --format='%s%x1f%b%x1e' 2>/dev/null |
  awk 'BEGIN { RS = "\036"; FS = "\037" }
       NF >= 1 {
         subject = $1; body = $2
         gsub(/^\n+/, "", subject); gsub(/^\n+/, "", body)
         if (subject == "") next
         if (subject ~ /^Merge pull request/) {
           split(body, lines, "\n"); title = lines[1]
           if (title != "") subject = title
         } else if (subject ~ /^Merge /) next
         print "- " subject
       }' > "$notes_dir/WhatToTest.en-US.txt" || true

exit 0
