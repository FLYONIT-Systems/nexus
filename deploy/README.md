# Deployment (Nexus, systemd + nginx)

Pushing to `main` runs CI. When CI passes, `deploy.yml` builds a bundle from that exact commit,
copies it to the server, and runs `deploy-nexus.sh`. The script backs up the database, installs the
new version beside the running one, health-checks it, and rolls back automatically if the check fails.

`rollback.yml` is a manual workflow that swaps back to the previous directory. It does not restore the database.

## One-time server setup
1. Create a deploy user (for example `nexus-deploy`) with SSH key login only.
2. Give it passwordless sudo only for what the scripts call: `systemctl stop|start|show|is-active` for the Nexus unit, `mv`, `cp`, `chown`, `mkdir`, `rm -rf` on the app directory. Do not give it blanket root.
3. Make sure `pg_dump` matches the server's PostgreSQL major version, and that Node 20 or newer is installed.
4. Keep `.env` and `mcp_settings.json` only in the live app directory. The deploy script copies them into each new release. They are never stored in git.

## GitHub setup (repo settings)
Create an environment named `production` (Settings, Environments). No required reviewers, because deploys are automatic on push to main.

Environment secrets:
- `DEPLOY_HOST`: server hostname or IP
- `DEPLOY_USER`: deploy user name
- `DEPLOY_SSH_KEY`: private key for the deploy user (generate a dedicated key, do not reuse a personal one)
- `DEPLOY_KNOWN_HOSTS`: output of `ssh-keyscan -t ed25519 <host>`, verified once against the server's fingerprint
- `NEXUS_SERVICE`: systemd unit name, for example `nexus`

Do not put any of these in the repo.

## Flow of a deploy
1. CI (`ci.yml`) runs lint, backend build, frontend typecheck, tests on Node 20 and 22, and a production audit that fails only on critical advisories.
2. On success, `deploy.yml` builds `dist`, `frontend/dist`, and the lockfile into `nexus-<sha>.deploy.tar.gz`.
3. The script on the server takes a `pg_dump` into the deploy user's home directory, installs with `pnpm install --frozen-lockfile`, swaps directories, restarts, and checks that the service is active, has not crash-looped, and answers HTTP on its port.
4. On failure it rolls back to the previous directory and keeps the failed copy as `<dir>.failed-<timestamp>`.

## Rollback
Run the "Rollback production" workflow manually and type `ROLLBACK`. It restores the most recent `<dir>.bak-<timestamp>`. If the new version changed the database schema, the old version usually still runs, but a full data rollback needs `pg_restore` from the dump taken at deploy time.

## Not included yet
- Upstream sync (tag-based, opens a PR). Planned next, along with the separate v1.1.12 upgrade.
- Automatic notifications on failed deploys.
