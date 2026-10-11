#!/usr/bin/env bash
# Exercises lock.sh with stand-ins for the runner processes of several jobs.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export HOME="$work/home"
locks="$HOME/.lock-action"
mkdir -p "$HOME"
export STEPS="$work/steps.sh"

# The steps that a job can call
cat > "$STEPS" << EOF
set -euo pipefail
acquire() { LOCK_NAME="\$1" bash "$here/../lock.sh" acquire; }
release() { LOCK_NAME="\$1" bash "$here/../lock.sh" release; }
run() { LOCK_NAME="\$1" LOCK_RUN="\$2" bash "$here/../lock.sh" run; }
EOF

# lock.sh finds its job by the name of the runner process, so a shell under that name stands in
# for one
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    cp "$(cygpath -u "$COMSPEC")" "$work/Runner.Worker.exe"
    worker() { "$work/Runner.Worker.exe" //c "bash $(cygpath -m "$1")"; }
    ;;
  *)
    ln -s "$BASH" "$work/Runner.Worker"
    worker() { "$work/Runner.Worker" "$1"; }
    ;;
esac

# Runs the steps given on stdin as one job
job() {
  local script
  script="$(mktemp "$work/job.XXXXXX")"
  {
    echo "source \"$STEPS\""
    cat
  } > "$script"
  worker "$script"
}

echo "--- run holds the lock for the script and releases it after"
job << 'EOF'
run basic '[ -d "$HOME/.lock-action/basic.lock" ] && touch "$HOME/ran"'
[ -e "$HOME/ran" ]
[ ! -e "$HOME/.lock-action/basic.lock" ]
EOF

echo "--- run passes on the status of a failed script and still releases"
job << 'EOF'
status=0
run failing 'exit 3' || status=$?
[ "$status" -eq 3 ]
[ ! -e "$HOME/.lock-action/failing.lock" ]
EOF

echo "--- a job holds the lock across steps until it releases it"
job << 'EOF'
acquire held
[ -d "$HOME/.lock-action/held.lock" ]
acquire held
run held 'true'
[ -d "$HOME/.lock-action/held.lock" ]
release held
[ ! -e "$HOME/.lock-action/held.lock" ]
release held
EOF

echo "--- another job cannot release the lock and waits for it"
job << 'EOF' &
acquire shared
touch "$HOME/first.holds"
until [ -e "$HOME/first.go" ]; do sleep 0.2; done
touch "$HOME/first.done"
release shared
EOF
first=$!
until [ -e "$HOME/first.holds" ]; do sleep 0.2; done
job << 'EOF'
release shared
[ -d "$HOME/.lock-action/shared.lock" ]
bash -c 'source "$STEPS" && acquire shared && touch "$HOME/second.holds"' &
waiter=$!
sleep 3
[ ! -e "$HOME/second.holds" ]
touch "$HOME/first.go"
wait "$waiter"
[ -e "$HOME/first.done" ]
release shared
[ ! -e "$HOME/.lock-action/shared.lock" ]
EOF
wait "$first"

echo "--- the lock of a job that ended without releasing it is taken over"
job << 'EOF'
acquire stale
EOF
[ -d "$locks/stale.lock" ]
job << 'EOF'
acquire stale
release stale
EOF
[ ! -e "$locks/stale.lock" ]

echo "--- the lock of a step that was killed stays with its job"
job << 'EOF'
run killed 'kill -9 $PPID' || true
[ -d "$HOME/.lock-action/killed.lock" ]
run killed 'true'
[ -d "$HOME/.lock-action/killed.lock" ]
EOF
job << 'EOF'
acquire killed
release killed
EOF
[ ! -e "$locks/killed.lock" ]

echo "--- a lock that was never claimed is taken over"
mkdir -p "$locks/unclaimed.lock" "$locks/unclaimed.turn"
touch -t 200001010000 "$locks/unclaimed.lock" "$locks/unclaimed.turn"
job << 'EOF'
acquire unclaimed
release unclaimed
EOF

echo "--- jobs never hold the lock at the same time"
jobs=()
for _ in 1 2 3 4; do
  job << 'EOF' &
for round in 1 2 3; do
  run mutex 'mkdir "$HOME/inside" && sleep 0.1 && rmdir "$HOME/inside"'
done
EOF
  jobs+=($!)
done
for pid in "${jobs[@]}"; do
  wait "$pid"
done

echo "All tests passed"
