# Lock Action

Hold a lock shared by every runner on a machine with this GitHub action.

Runners that share a machine often share tools such as Homebrew or rustup, which are not safe to
run at the same time. A job acquires the lock by name, and jobs on the other runners of that
machine wait for it.

## Options

| Name | Type   | Description                               |
|------|--------|-------------------------------------------|
| name | string | Name of the lock                          |
| run  | string | Bash script to run while holding the lock |

## Usage

*Running a script under a lock*

The lock is released when the script ends.

```yaml
- name: Install packages
  uses: snxd/lock-action@main
  with:
    name: brew
    run: |
      brew install cmake ninja
```

*Holding a lock across steps*

Without `run` the lock is held until `snxd/lock-action/release` runs or the job ends.

```yaml
- name: Acquire rustup lock
  uses: snxd/lock-action@main
  with:
    name: rustup

- name: Install rust
  uses: dtolnay/rust-toolchain@master
  with:
    toolchain: "1.99.0"

- name: Release rustup lock
  if: always()
  uses: snxd/lock-action/release@main
  with:
    name: rustup
```

*Running a PowerShell step under a lock*

The script in `run` is always run by Bash. A step that needs PowerShell holds the lock across
steps instead.

```yaml
- name: Acquire choco lock
  uses: snxd/lock-action@main
  with:
    name: choco

- name: Install packages
  shell: powershell
  run: |
    choco upgrade --no-progress -y `
      7zip `
      cmake

- name: Release choco lock
  if: always()
  uses: snxd/lock-action/release@main
  with:
    name: choco
```

## Behavior

* Locks are kept in `~/.lock-action`, so runners share them when they run as the same user.
* A lock belongs to the job that acquired it. Releasing a lock that the job does not hold does
  nothing, which makes `if: always()` safe on the release step.
* A lock whose job has ended is taken over by the next job that waits for it, so a cancelled job
  does not leave the lock stuck.
* Linux, macOS, and Windows are supported. Windows needs Git Bash and Windows PowerShell, which
  the action uses itself, and jobs that run in a container are not supported.
