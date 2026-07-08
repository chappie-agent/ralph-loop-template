#!/bin/bash
# kick-off.sh — Start a new project with a PRD interview.
# Usage: ./kick-off.sh
# Ask for a short description, then launch a deep interview that produces PRD.md.

echo ""
echo "Ralph kick-off"
echo "=============="
echo "Wat wil je maken? Geef een korte beschrijving:"
echo ""
read -r description

if [ -z "$description" ]; then
  echo "Geen beschrijving opgegeven. Gestopt."
  exit 1
fi

echo ""
echo "Starting interview for: $description"
echo ""

# Interactive on purpose (no -p): the interviewer relies on AskUserQuestion,
# which has no channel in headless print mode — a `-p` run would silently
# "interview" nobody and write a PRD full of assumptions.
claude "I want to build: $description

Use the interviewer subagent to interview me in depth. The interviewer will use the AskUserQuestion tool to ask questions one at a time, covering the core flow, edge cases, error states, auth, data model, UI expectations, and what is explicitly out of scope.

After the interview, the interviewer writes a complete, self-contained PRD to PRD.md as a checklist of small tasks. Each task must name the specific files involved and include a concrete end-to-end verification step.

Start the interview now."
